import ForgeCore
import ForgeData
import Foundation
import Observation
import SwiftData

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

    /// The payload of one HealthKit workout write, captured before dispatch so
    /// the seamed path — and the tests that count it — see exactly the values
    /// the live writer would receive. All fields are Sendable value types
    /// (Date, Bool, Double?, String?, and String-raw CardioKind).
    struct HealthKitSaveRequest: Sendable {
        let start: Date
        let end: Date
        let isCardio: Bool
        let isYoga: Bool
        let modality: CardioKind?
        let energyKcal: Double?
        let distanceMeters: Double?
        let effortScore: Double?
        let workoutName: String?
    }

    /// The terminal side-effect surface of a finished workout, injectable so
    /// tests can count HealthKit scheduling, Watch relay, and backup dispatch
    /// without claiming real HealthKit writes. The production default routes
    /// to the live services and preserves current behavior. Runtime teardown
    /// (`cancelLiveRuntime`) deliberately stays outside the seam: it is
    /// internally idempotent, so re-entry cannot duplicate a write.
    struct FinishEffects {
        var scheduleHealthKitSave: (HealthKitSaveRequest) -> Void
        var scheduleHeartRateSamples: ([(date: Date, bpm: Int)]) -> Void
        var sendWorkoutFinishedToWatch: () -> Void
        var publishWatchState: () -> Void
        var noteLogDataChanged: () -> Void

        /// The production implementation, rebuilt fresh per access so no
        /// caller can share mutable routing state with a test recorder. All
        /// closures run on the main actor (the module's default isolation)
        /// exactly like the calls they replace.
        static var live: FinishEffects {
            FinishEffects(
                scheduleHealthKitSave: { request in
                    Task {
                        await HealthService.shared.saveWorkout(
                            from: request.start, to: request.end,
                            isCardio: request.isCardio,
                            isYoga: request.isYoga,
                            modality: request.modality,
                            energyKcal: request.energyKcal,
                            distanceMeters: request.distanceMeters,
                            effortScore: request.effortScore,
                            workoutName: request.workoutName
                        )
                    }
                },
                scheduleHeartRateSamples: { samples in
                    Task { await HealthService.shared.saveHeartRateSamples(samples) }
                },
                sendWorkoutFinishedToWatch: {
                    WatchLink.shared.sendCommand(.workoutFinished)
                },
                publishWatchState: {
                    WatchLink.shared.publishDurableState()
                },
                noteLogDataChanged: {
                    BackupScheduler.shared.noteLogDataChanged()
                }
            )
        }
    }

    /// Rejects re-entry while a terminal action is in flight (FF-006 UI
    /// gate) and publishes the held state so Save surfaces can disable their
    /// commit control and show "Saving…" while held. Each phone Save surface
    /// holds one so a rapid second tap cannot re-enter the finisher; the
    /// persisted-state gate in `finish` remains the second, authoritative
    /// layer. The gate is released only when the finisher/save fails — a
    /// success keeps it held through dismissal.
    @MainActor
    @Observable
    final class InFlightGate {
        private(set) var isActive = false

        /// Returns true when the gate was free and is now held.
        @discardableResult
        func tryBegin() -> Bool {
            guard !isActive else { return false }
            isActive = true
            return true
        }

        /// Re-opens the gate (a failed save must stay retryable).
        func end() {
            isActive = false
        }
    }

    /// User choices made on the post-workout summary. These values must enter
    /// the same isolated transaction as the terminal workout save; mutating
    /// the long-lived SwiftUI context first makes the routine/RPE changes
    /// autosave-dependent and lets a terminal rollback produce a half-commit.
    struct SummaryCommit: Equatable {
        let wholeSessionRPE: Double?
        let wholeSessionRPERatedAt: Date?
        let wholeSessionRPEProtocolVersion: String?
        let updateRoutine: Bool

        init(
            wholeSessionRPE: Double?,
            wholeSessionRPERatedAt: Date?,
            wholeSessionRPEProtocolVersion: String?,
            updateRoutine: Bool
        ) {
            self.wholeSessionRPE = wholeSessionRPE
            self.wholeSessionRPERatedAt = wholeSessionRPERatedAt
            self.wholeSessionRPEProtocolVersion = wholeSessionRPEProtocolVersion
            self.updateRoutine = updateRoutine
        }
    }

    /// Returns an error message when the terminal save fails (the workout
    /// stays live and nothing downstream runs). `nil` is both a fresh success
    /// and a no-op success for an already-finished workout (FF-006). Callers
    /// with a UI surface the message; the watch path is best-effort.
    @MainActor
    @discardableResult
    static func finish(
        workoutID: UUID,
        in callerContext: ModelContext,
        liveMetrics: WatchLiveMetrics? = nil,
        watchSavedToHealth: Bool = false,
        endedAt requestedEnd: Date? = nil,
        summaryCommit: SummaryCommit? = nil,
        effects: FinishEffects? = nil,
        terminalSave: ((ModelContext) -> String?)? = nil
    ) -> String? {
        let transaction = ModelContext(callerContext.container)
        transaction.autosaveEnabled = false
        guard let workout = try? transaction.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first else {
            return "The active workout could not be found."
        }

        // An already-terminal workout is an exactly-once no-op. Do not apply a
        // summary or routine mutation on a repeated Save invocation.
        guard workout.endedAt == nil, workout.deletedAt == nil else {
            mirrorTerminalIdentity(of: workout, workoutID: workoutID, into: callerContext)
            return nil
        }

        let commitTimestamp = Date.now
        var routineMirror: (id: UUID, plan: RoutineChangeSync.Plan, timestamp: Date)?
        if let summaryCommit {
            ProgressionPlanner.resolveStatuses(for: workout, in: transaction)
            workout.wholeSessionRPE = summaryCommit.wholeSessionRPE
            workout.wholeSessionRPERatedAt = summaryCommit.wholeSessionRPERatedAt
            workout.wholeSessionRPEProtocolVersion = summaryCommit.wholeSessionRPEProtocolVersion

            if summaryCommit.updateRoutine {
                guard let routineID = workout.routineID else {
                    return "This workout is no longer linked to a routine. The workout is still active."
                }
                guard let routine = try? transaction.fetch(FetchDescriptor<RoutineModel>(
                    predicate: #Predicate { $0.id == routineID && $0.deletedAt == nil }
                )).first else {
                    return "The routine could not be found, so it was not updated. The workout is still active."
                }
                let plan = RoutineChangeSync.detect(workout: workout, routine: routine)
                if plan.hasChanges {
                    RoutineChangeSync.apply(
                        plan,
                        to: routine,
                        from: workout,
                        in: transaction,
                        now: commitTimestamp
                    )
                    routineMirror = (routineID, plan, commitTimestamp)
                }
            }
        }
        let failure = finish(
            workout,
            in: transaction,
            liveMetrics: liveMetrics,
            watchSavedToHealth: watchSavedToHealth,
            endedAt: requestedEnd,
            effects: effects,
            terminalSave: terminalSave,
            prepareLiveYogaRunnerBeforeSave: false
        )
        guard failure == nil else { return failure }
        mirrorTerminalIdentity(of: workout, workoutID: workoutID, into: callerContext)
        if let summaryCommit {
            mirrorSummaryCommit(
                summaryCommit,
                transactionWorkout: workout,
                workoutID: workoutID,
                transactionContext: transaction,
                into: callerContext
            )
        }
        if let routineMirror {
            let routineID = routineMirror.id
            if let callerWorkout = try? callerContext.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.id == workoutID }
            )).first,
               let callerRoutine = try? callerContext.fetch(FetchDescriptor<RoutineModel>(
                   predicate: #Predicate { $0.id == routineID && $0.deletedAt == nil }
               )).first {
                // The isolated context is durable truth. Mirror the same accepted
                // deterministic plan into the long-lived context only after that
                // save succeeds, so current UI state cannot remain stale and a
                // later autosave cannot resurrect removed relationship members.
                RoutineChangeSync.apply(
                    routineMirror.plan,
                    to: callerRoutine,
                    from: callerWorkout,
                    in: callerContext,
                    now: routineMirror.timestamp
                )
            }
        }
        return nil
    }

    /// Mirrors terminal identity from an isolated transaction back into the
    /// caller's long-lived instance.
    ///
    /// The isolated context is the durable source of truth, but the app's
    /// long-lived context can still hold the pre-transaction instance — and
    /// `ContentView`'s active-workout `@Query` (`endedAt == nil &&
    /// deletedAt == nil`) plus `WatchLink.buildContext` both observe *that*
    /// instance. Leaving it non-terminal is what makes an ended workout keep
    /// looking live: the sheet minimizes instead of dismissing, the workout
    /// never reaches history, and the Watch receives it again as a new live
    /// session. Every isolated path that ends a workout — finishing or
    /// discarding — must come back through here.
    @MainActor
    private static func mirrorTerminalIdentity(
        of workout: WorkoutModel,
        workoutID: UUID,
        into callerContext: ModelContext
    ) {
        guard let callerWorkout = try? callerContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first, callerWorkout !== workout else { return }
        callerWorkout.endedAt = workout.endedAt
        callerWorkout.deletedAt = workout.deletedAt
        callerWorkout.updatedAt = workout.updatedAt
    }

    /// Mirrors summary fields and resolved progression state after the
    /// isolated commit. No caller mutation happens on failure, keeping retry
    /// behavior exact and preventing a failed finish from looking completed.
    @MainActor
    private static func mirrorSummaryCommit(
        _ summary: SummaryCommit,
        transactionWorkout: WorkoutModel,
        workoutID: UUID,
        transactionContext: ModelContext,
        into callerContext: ModelContext
    ) {
        if let callerWorkout = try? callerContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first, callerWorkout !== transactionWorkout {
            callerWorkout.wholeSessionRPE = summary.wholeSessionRPE
            callerWorkout.wholeSessionRPERatedAt = summary.wholeSessionRPERatedAt
            callerWorkout.wholeSessionRPEProtocolVersion = summary.wholeSessionRPEProtocolVersion
        }

        let committedSuggestions = (try? transactionContext.fetch(FetchDescriptor<ProgressionSuggestionModel>(
            predicate: #Predicate { $0.workoutID == workoutID && $0.deletedAt == nil }
        ))) ?? []
        for committed in committedSuggestions {
            let suggestionID = committed.id
            guard let caller = try? callerContext.fetch(FetchDescriptor<ProgressionSuggestionModel>(
                predicate: #Predicate { $0.id == suggestionID }
            )).first else { continue }
            caller.statusRaw = committed.statusRaw
            caller.updatedAt = committed.updatedAt
        }
    }

    @MainActor
    @discardableResult
    static func finish(
        _ workout: WorkoutModel,
        in context: ModelContext,
        liveMetrics: WatchLiveMetrics? = nil,
        watchSavedToHealth: Bool = false,
        endedAt requestedEnd: Date? = nil,
        effects: FinishEffects? = nil,
        terminalSave: ((ModelContext) -> String?)? = nil,
        prepareLiveYogaRunnerBeforeSave: Bool = true
    ) -> String? {
        // Per-call injection (FF-006): tests hand in a recorder to count
        // dispatch, and a terminal-save stand-in to exercise failure. The
        // defaults keep every existing call site unchanged and, being
        // per-call, immunity to parallel-test races that a shared global
        // would invite.
        let dispatchedEffects = effects ?? .live
        let dispatchTerminalSave = terminalSave ?? { $0.saveReportingFailure() }
        // FF-006 exactly-once gate: terminal state that already committed
        // (finished, or discarded) makes this call a no-op success. `endedAt`
        // is only persisted by a successful terminal save below — a failed
        // save rolls back to nil and the workout stays live, so a retry is
        // still processed. Every downstream side effect (HealthKit, Watch
        // relay, XP/streak, backup) therefore fires at most once per workout,
        // while distinct workouts finish independently.
        guard workout.endedAt == nil, workout.deletedAt == nil else { return nil }
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

        // SwiftData's `rollback()` restores the store transaction, but model
        // references already held by SwiftUI can retain their just-mutated
        // scalar values. Capture every field this terminal pass changes so a
        // failed save is visibly and behaviorally live again in the same
        // context — most importantly `endedAt`, the idempotency gate for a
        // user's retry.
        let workoutBeforeFinish = (
            endedAt: workout.endedAt,
            totalVolume: workout.totalVolume,
            avgHR: workout.avgHR,
            maxHR: workout.maxHR,
            activeEnergyKcal: workout.activeEnergyKcal,
            hrZoneSeconds: workout.hrZoneSeconds,
            xpAwardedAmount: workout.xpAwardedAmount,
            xpAwardedAt: workout.xpAwardedAt,
            updatedAt: workout.updatedAt
        )
        let setEffortBeforeFinish = workout.exercises.flatMap(\.sets).map {
            (model: $0, rpe: $0.rpe, rir: $0.rir)
        }
        let blockStateBeforeFinish = workout.blocks.map {
            (model: $0, resultJSON: $0.resultJSON, updatedAt: $0.updatedAt)
        }
        let sessionStateBeforeFinish = workout.cardioSessions.map {
            (
                model: $0,
                endedAt: $0.endedAt,
                durationSeconds: $0.durationSeconds,
                distanceMeters: $0.distanceMeters,
                distanceSourceRaw: $0.distanceSourceRaw,
                elevationGainMeters: $0.elevationGainMeters,
                updatedAt: $0.updatedAt,
                yogaStyleRaw: $0.yogaStyleRaw,
                flexibilityExposureJSON: $0.flexibilityExposureJSON,
                posesCompleted: $0.posesCompleted,
                routePoints: $0.routePoints,
                splits: $0.splits
            )
        }
        let workoutUserID = workout.userID
        let progressBeforeFinish = ((try? context.fetch(FetchDescriptor<UserProgressModel>(
            predicate: #Predicate { $0.userID == workoutUserID && $0.deletedAt == nil }
        ))) ?? []).first.map {
            (model: $0, totalXP: $0.totalXP, level: $0.level, updatedAt: $0.updatedAt)
        }

        func restoreFailedTerminalMutation() {
            workout.endedAt = workoutBeforeFinish.endedAt
            workout.totalVolume = workoutBeforeFinish.totalVolume
            workout.avgHR = workoutBeforeFinish.avgHR
            workout.maxHR = workoutBeforeFinish.maxHR
            workout.activeEnergyKcal = workoutBeforeFinish.activeEnergyKcal
            workout.hrZoneSeconds = workoutBeforeFinish.hrZoneSeconds
            workout.xpAwardedAmount = workoutBeforeFinish.xpAwardedAmount
            workout.xpAwardedAt = workoutBeforeFinish.xpAwardedAt
            workout.updatedAt = workoutBeforeFinish.updatedAt
            for state in setEffortBeforeFinish {
                state.model.rpe = state.rpe
                state.model.rir = state.rir
            }
            for state in blockStateBeforeFinish {
                state.model.resultJSON = state.resultJSON
                state.model.updatedAt = state.updatedAt
            }
            for state in sessionStateBeforeFinish {
                state.model.endedAt = state.endedAt
                state.model.durationSeconds = state.durationSeconds
                state.model.distanceMeters = state.distanceMeters
                state.model.distanceSourceRaw = state.distanceSourceRaw
                state.model.elevationGainMeters = state.elevationGainMeters
                state.model.updatedAt = state.updatedAt
                state.model.yogaStyleRaw = state.yogaStyleRaw
                state.model.flexibilityExposureJSON = state.flexibilityExposureJSON
                state.model.posesCompleted = state.posesCompleted
                state.model.routePoints = state.routePoints
                state.model.splits = state.splits
            }
            if let progressBeforeFinish {
                progressBeforeFinish.model.totalXP = progressBeforeFinish.totalXP
                progressBeforeFinish.model.level = progressBeforeFinish.level
                progressBeforeFinish.model.updatedAt = progressBeforeFinish.updatedAt
            }
        }

        // Hidden effort must never leak into history, exports, analytics, or
        // HealthKit. Failure mode fills only unrated completed non-warm-up sets.
        WorkoutEffortPolicy.prepareForFinish(workout)
        let now = max(workout.startedAt, min(requestedEnd ?? .now, .now))
        let workoutExercisesByID = Dictionary(workout.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Deferred fills retain the container but never a context or model.
        // They carry IDs/value snapshots and refetch after each HealthKit await
        // so reset or history deletion cannot leave a stale model reference.
        let container = context.container
        // Build deferred work while terminal models are being finalized, but
        // do not launch any task until the one terminal save succeeds. A
        // failed save must leave no enrichment task racing the rollback.
        var deferredSessionEnrichments: [() -> Void] = []
        var routeSessionsPendingCommit = Set<UUID>()
        // Yoga completion checkpoints are transaction companions: retain
        // them through rollback, and remove them only after the terminal
        // SwiftData save commits.
        var yogaCheckpointsPendingCommit = Set<UUID>()
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
                // A live class mid-hold records the hold in progress exactly
                // as Skip does, so finishing the surrounding workout cannot
                // drop partial credit (FF-013). The runner does it while
                // alive; YogaSessionCompletion.complete reconciles the
                // terminated-app case where no runner exists.
                if prepareLiveYogaRunnerBeforeSave {
                    YogaFlowRunnerHub.shared.complete(for: session.id, persist: false)
                }
                YogaSessionCompletion.complete(
                    session: session,
                    workoutExercise: workoutExercise,
                    exercise: exercise,
                    context: context,
                    endedAt: now,
                    useClockDuration: wasLive,
                    clearCheckpoint: false
                )
                yogaCheckpointsPendingCommit.insert(session.id)
                guard wasLive else { continue }
                let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: now)
                let enrichmentRequest = DeferredWorkoutEnrichmentCoordinator.SessionRequest(
                    sessionID: session.id,
                    workoutID: workout.id,
                    start: start,
                    end: now,
                    modality: .other,
                    fallbackAvgHR: bleStats?.avgHR,
                    fallbackMaxHR: bleStats?.maxHR,
                    importsDistance: false,
                    providesGPSDistance: false,
                    hadManualIntervalPlan: false
                )
                deferredSessionEnrichments.append {
                    DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
                        enrichmentRequest,
                        container: container
                    )
                }
            } else if session.liveStartedAt != nil {
                let workoutExercise = session.workoutExerciseID.flatMap { workoutExercisesByID[$0] }
                let exercise = exercise(for: workoutExercise, in: context)
                let providesGPSDistance = CardioKind.providesGPSDistance(name: exercise?.name ?? "", equipment: exercise?.equipment)
                let start = session.liveStartedAt ?? session.startedAt
                session.endedAt = now
                session.durationSeconds = max(1, Int(now.timeIntervalSince(start)))
                if providesGPSDistance {
                    CardioRouteRecorder.shared.stageRouteForTerminalSave(
                        session: session,
                        in: context
                    )
                    routeSessionsPendingCommit.insert(session.id)
                }
                let kind = CardioKind.from(modality: session.modality)
                let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: now)
                let hadManualIntervalPlan = workoutExercise
                    .flatMap { IntervalPlan.decode(from: $0.intervalPlanJSON)?.hasSteps } == true
                let enrichmentRequest = DeferredWorkoutEnrichmentCoordinator.SessionRequest(
                    sessionID: session.id,
                    workoutID: workout.id,
                    start: start,
                    end: now,
                    modality: kind,
                    fallbackAvgHR: bleStats?.avgHR,
                    fallbackMaxHR: bleStats?.maxHR,
                    importsDistance: true,
                    providesGPSDistance: providesGPSDistance,
                    hadManualIntervalPlan: hadManualIntervalPlan
                )
                deferredSessionEnrichments.append {
                    DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
                        enrichmentRequest,
                        container: container
                    )
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
        XPService.stageXPIfNeeded(for: workout, in: context, now: now)
        // Terminal save: if this fails, NOTHING committed (rollback undid
        // endedAt/XP/cardio completions) — the workout is still live, so skip
        // every downstream write and let the caller surface the failure.
        if let failure = dispatchTerminalSave(context) {
            restoreFailedTerminalMutation()
            return failure
        }
        routeSessionsPendingCommit.forEach {
            CardioRouteRecorder.shared.cancel(sessionID: $0)
        }
        yogaCheckpointsPendingCommit.forEach {
            YogaRuntimeCheckpointStore.clear(sessionID: $0)
        }
        deferredSessionEnrichments.forEach { $0() }

        let start = workout.startedAt
        if workout.avgHR == nil || workout.maxHR == nil || workout.activeEnergyKcal == nil {
            DeferredWorkoutEnrichmentCoordinator.shared.scheduleWorkout(
                .init(workoutID: workout.id, start: start, end: now),
                container: container
            )
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
            dispatchedEffects.scheduleHealthKitSave(HealthKitSaveRequest(
                start: start, end: now,
                isCardio: (pureSessions && !pureYoga) || pureConditioningBlocks,
                isYoga: pureYoga,
                modality: cardioKind ?? (pureConditioningBlocks ? .other : nil),
                energyKcal: energy, distanceMeters: distance,
                effortScore: effortScore,
                workoutName: workout.title
            ))
        }
        // BLE-monitor heart rate goes to Health under the same toggle, and is
        // skipped when the watch streamed (its session already wrote HR —
        // writing ours too would double-plot every graph).
        if writeEnabled && !watchSavedToHealth && !bleSamples.isEmpty {
            dispatchedEffects.scheduleHeartRateSamples(bleSamples.map { (date: $0.date, bpm: $0.bpm) })
        }

        // Tell the watch the session is over and refresh its snapshot.
        dispatchedEffects.sendWorkoutFinishedToWatch()
        dispatchedEffects.publishWatchState()
        cancelLiveRuntime()
        // A finished workout is the log change that matters most — refresh
        // the sanitized iCloud backup (debounced).
        dispatchedEffects.noteLogDataChanged()
        return nil
    }

    /// Returns an error message when the tombstone save fails (rollback keeps
    /// the workout live instead of leaving a phantom-deleted row) — `nil` on
    /// success.
    @MainActor
    @discardableResult
    static func discard(workoutID: UUID, in callerContext: ModelContext) -> String? {
        let transaction = ModelContext(callerContext.container)
        transaction.autosaveEnabled = false
        guard let workout = try? transaction.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first else {
            return "The active workout could not be found."
        }
        if let failure = discard(workout, in: transaction) { return failure }
        mirrorTerminalIdentity(of: workout, workoutID: workoutID, into: callerContext)
        return nil
    }

    @MainActor
    @discardableResult
    static func discard(_ workout: WorkoutModel, in context: ModelContext) -> String? {
        // FF-006 repeat-discard no-op: an already-tombstoned workout must not
        // re-run the Watch relay or runtime teardown for one user action.
        guard workout.deletedAt == nil else { return nil }
        let previousUpdatedAt = workout.updatedAt
        let previousDeletedAt = workout.deletedAt
        let now = Date()
        workout.updatedAt = now
        workout.deletedAt = now
        if let failure = context.saveReportingFailure() {
            workout.updatedAt = previousUpdatedAt
            workout.deletedAt = previousDeletedAt
            return failure
        }
        // Tell the watch the workout is gone. Phone-initiated discards remain
        // authoritative on the watch (it clears unconditionally); the carried
        // ID keeps the wire shape uniform with the watch → phone direction.
        WatchLink.shared.sendCommand(.discardWorkout(workoutID: workout.id))
        WatchLink.shared.publishDurableState()
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
        YogaFlowRunnerHub.shared.stop(clearCheckpoint: true)
        NotificationScheduler.shared.cancelWorkoutCues()
        LiveMetricsHub.shared.endSession()
        BLEHeartRateService.shared.stopWorkoutConnection()
        // Back to idle, but the workout ending says nothing about today's
        // readiness: saving a bare idle snapshot here erased the score every
        // shipped surface reads, the Watch complication included, and only
        // Home could put it back.
        ReadinessSurfacePublisher.publishIdle()
    }

    /// Cancel runtime work owned by one deleted/replaced cardio session while
    /// leaving the surrounding mixed workout alive.
    @MainActor
    static func cancelLiveRuntime(for session: CardioSessionModel) {
        CardioGoalAnnouncer.shared.cancel(sessionID: session.id)
        CardioRouteRecorder.shared.cancel(sessionID: session.id)
        IntervalRunnerHub.shared.stop(for: session.id)
        YogaFlowRunnerHub.shared.stop(for: session.id, clearCheckpoint: true)
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
