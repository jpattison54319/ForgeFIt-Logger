import ForgeCore
import ForgeData
import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared end-of-workout pipeline, used by both the on-phone logger and
/// watch-initiated finishes so the two paths can't drift:
/// 1. auto-complete any running cardio segment (+ HealthKit auto-fill),
/// 2. stamp session health metrics onto the workout (live metrics from the
///    watch or a BLE heart-rate monitor win, HealthKit window query fills
///    whatever they couldn't provide),
/// 3. write the HKWorkout back to Apple Health (unless the watch already did),
/// 4. kick a cloud sync.
enum WorkoutFinisher {

    /// A started, untimed fixed-work conditioning section cannot be saved as
    /// a DNF. Planned-but-never-started blocks may still be skipped in a mixed
    /// workout, and an explicit time cap remains an honest stopping condition.
    @MainActor
    static func conditioningTargetBlocker(in workout: WorkoutModel) -> String? {
        if let plan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON),
           let progress = ConditioningProgress.decode(from: workout.conditioningProgressJSON),
           progress.status != .ready,
           let message = conditioningTargetMessage(progress: progress, plan: plan) {
            return message
        }

        for block in workout.blocks where block.kind == .conditioning {
            guard let plan = ConditioningPlan.decode(from: block.planSnapshotJSON),
                  let progress = ConditioningProgress.decode(from: block.progressJSON),
                  progress.status != .ready,
                  let message = conditioningTargetMessage(progress: progress, plan: plan) else { continue }
            return message
        }
        return nil
    }

    private static func conditioningTargetMessage(
        progress: ConditioningProgress,
        plan: ConditioningPlan
    ) -> String? {
        let remaining = ConditioningProgressEngine.requiredRoundsRemaining(for: progress, plan: plan)
        guard remaining > 0 else { return nil }
        return "Complete \(remaining) more conditioning round\(remaining == 1 ? "" : "s") before saving. The clock keeps running until the target is complete."
    }

    /// A workout is worth keeping when something actually happened: a
    /// completed set, a cardio/yoga session that ran live or was deliberately
    /// logged, or typed workout/exercise notes (never silently delete typed text).
    /// An untouched planned block counts for nothing — matching the
    /// auto-complete rules below, which ignore sessions that never started.
    @MainActor
    static func hasSubstance(_ workout: WorkoutModel) -> Bool {
        if workout.blocks.contains(where: { block in
            if let progress = ConditioningProgress.decode(from: block.progressJSON),
               progress.status != .ready
                    || progress.fullRounds > 0
                    || !progress.completedMovementIDs.isEmpty {
                return true
            }
            if let result = ConditioningResult.decode(from: block.resultJSON),
               !result.sectionResults.isEmpty {
                return true
            }
            return false
        }) {
            return true
        }
        if let progress = ConditioningProgress.decode(from: workout.conditioningProgressJSON),
           progress.fullRounds > 0 || !progress.completedMovementIDs.isEmpty {
            return true
        }
        if let result = ConditioningResult.decode(from: workout.conditioningResultJSON),
           !result.sectionResults.isEmpty {
            return true
        }
        if WorkoutNotePolicy.userText(in: workout) != nil {
            return true
        }
        if workout.exercises.contains(where: { we in we.sets.contains { $0.completedAt != nil } }) {
            return true
        }
        if workout.cardioSessions.contains(where: { session in
            guard session.deletedAt == nil else { return false }
            return session.endedAt != nil
                || session.liveStartedAt != nil
                || (session.isYogaSession && session.sourceDevice == CardioSessionModel.yogaManualSource)
        }) {
            return true
        }
        return workout.exercises.contains { !($0.notes ?? "").isEmpty }
    }

    /// Returns an error message when the terminal save fails (the workout
    /// stays live and nothing downstream runs) — `nil` on success. Callers
    /// with a UI surface the message; the watch path is best-effort.
    @MainActor
    @discardableResult
    static func finish(
        _ workout: WorkoutModel,
        in context: ModelContext,
        liveMetrics: WatchLiveMetrics? = nil,
        watchSavedToHealth: Bool = false,
        endedAt requestedEnd: Date? = nil
    ) -> String? {
        if let blocker = conditioningTargetBlocker(in: workout) {
            return blocker
        }
        // Finishing an empty workout is a discard, not a completion: nothing
        // lands in history, no XP is awarded, and no phantom HKWorkout is
        // written to Apple Health. The phone UI asks before getting here;
        // this guard makes the rule hold for watch-initiated finishes too.
        guard hasSubstance(workout) else {
            return discard(workout, in: context)
        }
        // Hidden effort must never leak into history, exports, analytics, or
        // HealthKit. Failure mode fills only unrated completed non-warm-up sets.
        WorkoutEffortPolicy.prepareForFinish(workout)
        let now = max(workout.startedAt, min(requestedEnd ?? .now, .now))
        let workoutExercisesByID = Dictionary(workout.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The deferred HealthKit fills below outlive this call. If the
        // container deinits first (unit tests; theoretical shutdown races),
        // its context resets and every captured model is destroyed — touching
        // one is a fatal error. Each deferred Task retains the container so
        // the store outlives the fill.
        let container = context.container
        // BLE-monitor readings buffered for this session — captured now,
        // before endLiveSurfaces() drops the buffer, for the deferred fills
        // and the HealthKit write below.
        let bleSamples = LiveMetricsHub.shared.bleSamples(from: workout.startedAt, to: now)

        // A minimized conditioning runner can still be active when the user
        // finishes the surrounding workout. Preserve its completed-round
        // score before the shared cardio session loop closes its timing window.
        for block in workout.blocks where block.kind == .conditioning {
            guard workout.cardioSessions.contains(where: {
                $0.workoutBlockID == block.id
                    && $0.workoutExerciseID == nil
                    && $0.liveStartedAt != nil
                    && $0.endedAt == nil
            }),
            let plan = ConditioningPlan.decode(from: block.planSnapshotJSON),
            let progress = ConditioningProgress.decode(from: block.progressJSON) else { continue }
            block.resultJSON = ConditioningProgressEngine.result(for: progress, plan: plan).encodedJSON()
            block.updatedAt = now
        }

        // 1. Auto-complete running cardio/yoga segments and finalize manual
        // yoga logs. Cardio keeps the old "only if live" behavior; yoga also
        // supports pre-start manual duration/style entry.
        for session in workout.cardioSessions where session.endedAt == nil {
            if session.isYogaSession {
                let workoutExercise = session.workoutExerciseID.flatMap { workoutExercisesByID[$0] }
                let exercise = exercise(for: workoutExercise, in: context)
                let wasLive = session.liveStartedAt != nil
                let start = session.liveStartedAt ?? session.startedAt
                // Only sessions that actually happened complete here: a live
                // class, or a deliberate manual log (the manual editor stamps
                // the source). An untouched yoga block must NOT be logged as
                // done at its planned length — that would award XP and
                // flexibility credit for skipped practice. (Matches cardio,
                // whose non-live sessions are left alone.)
                guard wasLive || session.sourceDevice == CardioSessionModel.yogaManualSource else { continue }
                YogaSessionCompletion.complete(
                    session: session,
                    workoutExercise: workoutExercise,
                    exercise: exercise,
                    context: context,
                    endedAt: now,
                    useClockDuration: wasLive
                )
                guard wasLive else { continue }
                let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: now)
                Task { @MainActor in
                    defer { withExtendedLifetime(container) {} }
                    let snap = await HealthService.shared.importSnapshot(from: start, to: now, modality: .other)
                    if let hr = snap.avgHR ?? bleStats?.avgHR { session.avgHR = hr }
                    if let mx = snap.maxHR ?? bleStats?.maxHR { session.maxHR = mx }
                    if let e = snap.activeEnergyKcal { session.activeEnergyKcal = e }
                    // Distance is meaningless on the mat — a same-window walk
                    // sample must not become "yoga distance".
                    // Provisional estimate; finalize() replaces it with the
                    // measured distribution when the HR series has coverage.
                    session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
                    try? context.save()
                    await CardioSeriesService.finalize(session: session, hadManualIntervalPlan: false, in: context)
                }
            } else if session.liveStartedAt != nil {
                let workoutExercise = session.workoutExerciseID.flatMap { workoutExercisesByID[$0] }
                let exercise = exercise(for: workoutExercise, in: context)
                let providesGPSDistance = CardioKind.providesGPSDistance(name: exercise?.name ?? "", equipment: exercise?.equipment)
                let start = session.liveStartedAt ?? session.startedAt
                session.endedAt = now
                session.durationSeconds = max(1, Int(now.timeIntervalSince(start)))
                if providesGPSDistance {
                    CardioRouteRecorder.shared.stop(session: session, in: context)
                }
                let kind = CardioKind.from(modality: session.modality)
                let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: now)
                let hadManualIntervalPlan = workoutExercise
                    .flatMap { IntervalPlan.decode(from: $0.intervalPlanJSON)?.hasSteps } == true
                Task { @MainActor in
                    defer { withExtendedLifetime(container) {} }
                    let snap = await HealthService.shared.importSnapshot(from: start, to: now, modality: kind)
                    if let hr = snap.avgHR ?? bleStats?.avgHR { session.avgHR = hr }
                    if let mx = snap.maxHR ?? bleStats?.maxHR { session.maxHR = mx }
                    if let e = snap.activeEnergyKcal { session.activeEnergyKcal = e }
                    if let dist = snap.distanceMeters, !(providesGPSDistance && session.routePoints.count >= 2) {
                        session.distanceMeters = dist
                    }
                    // Provisional estimate; finalize() replaces it with the
                    // measured distribution when the HR series has coverage.
                    session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
                    try? context.save()
                    await CardioSeriesService.finalize(session: session, hadManualIntervalPlan: hadManualIntervalPlan, in: context)
                }
            }
        }

        // 2. Session metrics: live data (watch or BLE monitor) is the best
        //    source; a HealthKit window query fills any field it couldn't
        //    provide — a bare heart-rate monitor knows no calories, and with
        //    no live source at all everything comes from HealthKit.
        if let liveMetrics {
            apply(liveMetrics, to: workout)
        }
        workout.endedAt = now
        workout.recomputeTotalVolume()
        XPService.awardXPIfNeeded(for: workout, in: context, now: now)
        // Terminal save: if this fails, NOTHING committed (rollback undid
        // endedAt/XP/cardio completions) — the workout is still live, so skip
        // every downstream write and let the caller surface the failure.
        if let failure = context.saveReportingFailure() {
            return failure
        }

        let start = workout.startedAt
        if workout.avgHR == nil || workout.maxHR == nil || workout.activeEnergyKcal == nil {
            Task { @MainActor in
                defer { withExtendedLifetime(container) {} }
                let snap = await HealthService.shared.importSnapshot(from: start, to: now, modality: .other)
                if workout.avgHR == nil, let hr = snap.avgHR { workout.avgHR = hr }
                if workout.maxHR == nil, let mx = snap.maxHR { workout.maxHR = mx }
                if workout.activeEnergyKcal == nil, let e = snap.activeEnergyKcal { workout.activeEnergyKcal = e }
                try? context.save()
            }
        }

        // 3. Write to Apple Health — skipped when the watch's live workout
        //    builder already saved the session (avoids double-counting).
        let writeEnabled = UserDefaults.standard.object(forKey: "healthWriteEnabled") == nil
            || UserDefaults.standard.bool(forKey: "healthWriteEnabled")
        if writeEnabled && !watchSavedToHealth {
            let energy = workout.activeEnergyKcal
                ?? workout.cardioSessions.compactMap { $0.activeEnergyKcal }.reduce(0, +).nonZero
            let distance = workout.cardioSessions.compactMap { $0.distanceMeters }.reduce(0, +).nonZero
            // The activity type comes from the first *real* cardio session;
            // a session-only workout that is all yoga writes as `.yoga`.
            let cardioKind = workout.cardioSessions.first {
                !$0.isWorkoutBlockSession && !$0.isYogaSession && !$0.isConditioningSession
            }
                .map { CardioKind.from(modality: $0.modality) }
            let visibleExercises = workout.exercises.filter { $0.generatedByWorkoutBlockID == nil }
            let pureSessions = !visibleExercises.isEmpty
                && visibleExercises.allSatisfy { we in workout.cardioSessions.contains { $0.workoutExerciseID == we.id } }
                && workout.blocks.isEmpty
            let completedBlockKinds = workout.blocks.compactMap { block in
                workout.cardioSessions.contains { $0.workoutBlockID == block.id && $0.endedAt != nil }
                    ? block.kind
                    : nil
            }
            let pureYogaBlocks = visibleExercises.isEmpty
                && !completedBlockKinds.isEmpty
                && completedBlockKinds.allSatisfy { $0 == .yoga }
            let pureConditioningBlocks = visibleExercises.isEmpty
                && !completedBlockKinds.isEmpty
                && completedBlockKinds.allSatisfy { $0 == .conditioning }
            let pureYoga = (pureSessions && workout.cardioSessions.allSatisfy(\.isYogaSession)) || pureYogaBlocks
            // A genuine whole-session rating is the preferred HealthKit
            // effort. Older workouts fall back to their directly logged
            // cardio/set ratings, never to an inferred default.
            let effortScore: Double? = {
                if let sessionRPE = workout.wholeSessionRPE { return sessionRPE }
                var values = workout.cardioSessions.compactMap { $0.effort.map(Double.init) }
                let rpes = workout.exercises.flatMap(\.sets)
                    .filter { $0.completedAt != nil }
                    .compactMap(\.rpe)
                if !rpes.isEmpty { values.append(rpes.reduce(0, +) / Double(rpes.count)) }
                guard !values.isEmpty else { return nil }
                return values.reduce(0, +) / Double(values.count)
            }()
            Task {
                await HealthService.shared.saveWorkout(
                    from: start, to: now,
                    isCardio: (pureSessions && !pureYoga) || pureConditioningBlocks,
                    isYoga: pureYoga,
                    modality: cardioKind ?? (pureConditioningBlocks ? .other : nil),
                    energyKcal: energy, distanceMeters: distance,
                    effortScore: effortScore,
                    workoutName: workout.title
                )
            }
        }
        // BLE-monitor heart rate goes to Health under the same toggle, and is
        // skipped when the watch streamed (its session already wrote HR —
        // writing ours too would double-plot every graph).
        if writeEnabled && !watchSavedToHealth && !bleSamples.isEmpty {
            let samples = bleSamples.map { (date: $0.date, bpm: $0.bpm) }
            Task { await HealthService.shared.saveHeartRateSamples(samples) }
        }

        // Tell the watch the session is over and refresh its snapshot.
        WatchLink.shared.sendCommand(.workoutFinished)
        WatchLink.shared.publishState()
        cancelLiveRuntime()
        // A finished workout is the log change that matters most — refresh
        // the sanitized iCloud backup (debounced).
        BackupScheduler.shared.noteLogDataChanged()
        return nil
    }

    /// Returns an error message when the tombstone save fails (rollback keeps
    /// the workout live instead of leaving a phantom-deleted row) — `nil` on
    /// success.
    @MainActor
    @discardableResult
    static func discard(_ workout: WorkoutModel, in context: ModelContext) -> String? {
        let now = Date()
        workout.updatedAt = now
        workout.deletedAt = now
        if let failure = context.saveReportingFailure() {
            return failure
        }
        // Tell the watch the workout is gone. Phone-initiated discards remain
        // authoritative on the watch (it clears unconditionally); the carried
        // ID keeps the wire shape uniform with the watch → phone direction.
        WatchLink.shared.sendCommand(.discardWorkout(workoutID: workout.id))
        WatchLink.shared.publishState()
        cancelLiveRuntime()
        return nil
    }

    static func apply(_ metrics: WatchLiveMetrics, to workout: WorkoutModel) {
        if let hr = metrics.avgHR { workout.avgHR = hr }
        if let mx = metrics.maxHR { workout.maxHR = mx }
        if let e = metrics.activeEnergyKcal { workout.activeEnergyKcal = e }
        if metrics.hrZoneSeconds.contains(where: { $0 > 0 }) {
            workout.hrZoneSeconds = metrics.hrZoneSeconds
        }
    }

    @MainActor
    private static func exercise(for workoutExercise: WorkoutExerciseModel?, in context: ModelContext) -> ExerciseLibraryModel? {
        guard let exerciseID = workoutExercise?.exerciseID else { return nil }
        return (try? context.fetch(
            FetchDescriptor<ExerciseLibraryModel>(predicate: #Predicate { $0.id == exerciseID })
        ))?.first
    }

    /// One idempotent terminal path for every process-owned workout resource.
    /// Finishing, discarding, account reset, remote deletion, and lifecycle
    /// reconciliation all call this so no timer, sensor, cue, or Live Activity
    /// can survive after the model stops being live.
    @MainActor
    static func cancelLiveRuntime() {
        CardioGoalAnnouncer.shared.cancelAll()
        CardioRouteRecorder.shared.cancel()
        WorkoutActivityController.shared.end()
        RestTimerController.shared.skip()
        TimerChime.shared.stop()
        IntervalRunnerHub.shared.stop()
        HRZoneGuard.shared.deactivate()
        PaceGuard.shared.deactivate()
        PaceAnnouncer.shared.stop()
        YogaFlowRunnerHub.shared.stop()
        NotificationScheduler.shared.cancelWorkoutCues()
        LiveMetricsHub.shared.endSession()
        BLEHeartRateService.shared.stopWorkoutConnection()
        ForgeFitWidgetSnapshotStore.save(ForgeFitWidgetSnapshot(mode: .idle))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }

    /// Cancel runtime work owned by one deleted/replaced cardio session while
    /// leaving the surrounding mixed workout alive.
    @MainActor
    static func cancelLiveRuntime(for session: CardioSessionModel) {
        CardioGoalAnnouncer.shared.cancel(sessionID: session.id)
        CardioRouteRecorder.shared.cancel(sessionID: session.id)
        IntervalRunnerHub.shared.stop(for: session.id)
        YogaFlowRunnerHub.shared.stop(for: session.id)
        guard session.liveStartedAt != nil, session.endedAt == nil else { return }
        HRZoneGuard.shared.deactivate()
        PaceGuard.shared.deactivate()
        PaceAnnouncer.shared.stop()
        NotificationScheduler.shared.cancelCardioCues()
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
