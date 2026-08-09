import ForgeCore
import ForgeData
import Foundation
import Observation
import SwiftData
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// The phone side of live Apple Watch sync.
///
/// The phone owns the data. It publishes a `WatchAppContext` snapshot (active
/// workout, routines, readiness) through the WCSession application context on
/// every relevant change, and applies `WatchCommand`s coming back from the
/// wrist — set completions, cardio start/stop, live health metrics, and
/// start/finish/discard — directly to SwiftData. Also exposes pairing status
/// for Settings.
@MainActor
@Observable
final class WatchLink: NSObject {
    enum PublishPolicy {
        case interactionDeferred
        case immediate
    }

    static let shared = WatchLink()

    // Pairing status (Settings).
    var isSupported = false
    var isPaired = false
    var isWatchAppInstalled = false
    var isReachable = false

    /// Set by ContentView so watch-initiated starts/finishes can drive the UI.
    var onWorkoutStartedFromWatch: (() -> Void)?
    var onWorkoutFinishedFromWatch: (() -> Void)?

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private let interactionPublisher = DeferredInteractionWork()
    @ObservationIgnored private var routineSummaryCache: [WatchRoutineSummary]?

    func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { isSupported = false; return }
        isSupported = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refresh()
        #endif
    }

    /// Give the link data access; called once from ContentView.
    func configure(context: ModelContext) {
        modelContext = context
        // Timer changes are interaction-driven. Let the local timer repaint
        // immediately, while coalescing Watch snapshot construction off the
        // completion/adjustment run-loop turn.
        RestTimerController.shared.onStateChange = { [weak self] in
            self?.publishState(policy: .interactionDeferred)
        }
    }

    private func refresh() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
        #endif
    }

    // MARK: - Publish (phone → watch)

    /// Push the current app snapshot to the watch. Interaction changes are
    /// coalesced so snapshot fetches and serialization never share the input
    /// event's run-loop turn. Lifecycle/terminal callers use `.immediate`.
    func publishState(policy: PublishPolicy = .interactionDeferred) {
        switch policy {
        case .interactionDeferred:
            interactionPublisher.schedule { [weak self] in
                self?.publishStateNow()
            }
        case .immediate:
            interactionPublisher.cancel()
            publishStateNow()
        }
    }

    /// Compatibility for existing lifecycle call sites while policies migrate.
    func publishState(force: Bool) {
        publishState(policy: force ? .immediate : .interactionDeferred)
    }

    func invalidateRoutineSummaryCache() {
        routineSummaryCache = nil
    }

    private func publishStateNow() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let context = modelContext else { return }
        refresh()
        guard isWatchAppInstalled || WCSession.default.isReachable else { return }
        guard let data = WatchWire.encode(buildContext(in: context)) else { return }
        let payload = [WatchWire.contextKey: data]
        try? WCSession.default.updateApplicationContext(payload)
        // Application context can coalesce; when the watch is live, message it
        // for instant UI updates too.
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        #endif
    }

    private func buildContext(in context: ModelContext) -> WatchAppContext {
        let active = (try? context.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.deletedAt == nil && $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )))?.first
        // Library rows are needed only to describe the ACTIVE workout's
        // exercises (a dozen rows at most). This publish path fires up to
        // ~3×/s during logging (rest timer, interval steps, set edits) —
        // fetching the whole ~900-row library each time was a main-thread
        // hitch on every rest-timer start. Routine summaries need no library
        // rows, and idle readiness fetches inside its own cache-miss branch.
        var exerciseByID: [UUID: ExerciseLibraryModel] = [:]
        if let active {
            var referencedIDs = Set(active.exercises.map(\.exerciseID))
            for block in active.blocks {
                if block.kind == .conditioning,
                   let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) {
                    referencedIDs.formUnion(plan.sections.flatMap(\.movements).map(\.exerciseID))
                } else if block.kind == .yoga,
                          let plan = YogaFlowPlan.decode(from: block.planSnapshotJSON) {
                    referencedIDs.formUnion(plan.steps.map(\.poseID))
                }
            }
            let ids = Array(referencedIDs)
            let scoped = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>(
                predicate: #Predicate { ids.contains($0.id) && $0.deletedAt == nil }
            ))) ?? []
            exerciseByID = Dictionary(scoped.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        let routineSummaries: [WatchRoutineSummary]
        if let routineSummaryCache {
            routineSummaries = routineSummaryCache
        } else {
            let routines = (try? context.fetch(FetchDescriptor<RoutineModel>(
                predicate: #Predicate { $0.deletedAt == nil && $0.archivedAt == nil },
                sortBy: [SortDescriptor(\.position)]
            ))) ?? []
            let alternations = (try? context.fetch(FetchDescriptor<RoutineAlternationModel>(
                predicate: #Predicate { $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))) ?? []
            let completedWorkouts = (try? context.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.endedAt != nil && $0.deletedAt == nil },
                sortBy: [SortDescriptor(\.endedAt, order: .reverse)]
            ))) ?? []
            var pairPresentationByRoutineID: [UUID: (partnerName: String, isNext: Bool)] = [:]
            for state in RoutineAlternationService.states(
                alternations: alternations,
                routines: routines,
                workouts: completedWorkouts
            ) {
                pairPresentationByRoutineID[state.owner.id] = (
                    state.partner.name,
                    state.due.id == state.owner.id
                )
                pairPresentationByRoutineID[state.partner.id] = (
                    state.owner.name,
                    state.due.id == state.partner.id
                )
            }
            let summaries = routines
                .filter { $0.deletedAt == nil && (!$0.exercises.isEmpty || !$0.blocks.isEmpty) }
                .sorted { $0.position < $1.position }
                .map { routine in
                    let pair = pairPresentationByRoutineID[routine.id]
                    return WatchRoutineSummary(
                        id: routine.id,
                        name: routine.name,
                        exerciseCount: routine.exercises.count + routine.blocks.count,
                        alternatingPartnerName: pair?.partnerName,
                        isNextInAlternation: pair?.isNext
                    )
                }
            routineSummaryCache = summaries
            routineSummaries = summaries
        }

        // Home's widget payload is the lightweight cross-surface cache. Watch
        // activation must never rebuild workout history on MainActor.
        let idleReadiness = active == nil
            ? ForgeFitWidgetSnapshotStore.load().flatMap { $0.mode == .idle ? $0 : nil }
            : nil
        let readiness = active?.readinessAtStart ?? idleReadiness?.readinessScore

        var snapshot: WatchWorkoutSnapshot?
        if let active {
            let timer = RestTimerController.shared
            // The zone target of the cardio segment currently recording, so
            // the watch can run its own low-latency haptic guard. A live
            // interval runner takes precedence — its per-step zone (work Z4,
            // recover Z3) is the target to hold right now.
            let activeZoneTarget: Int? = IntervalRunnerHub.shared.runner?.currentZoneTarget
                ?? active.cardioSessions
                    .first { $0.liveStartedAt != nil && $0.endedAt == nil }
                    .flatMap { session in active.exercises.first { $0.id == session.workoutExerciseID } }
                    .flatMap { IntervalPlan.decode(from: $0.intervalPlanJSON)?.hrZoneTarget }
            // At most one timed runner is live (interval XOR yoga); either
            // one mirrors into the same step fields the watch already renders.
            let intervalRunner = IntervalRunnerHub.shared.runner
            let yogaRunner = YogaFlowRunnerHub.shared.runner
            // Distance steps have no wall-clock end: the wrist shows the
            // step + its distance target instead of a countdown.
            let stepName: String? = {
                guard let step = intervalRunner?.currentStep else { return nil }
                if step.isDistanceBased, let meters = step.distanceMeters {
                    return "\(step.label) · \(IntervalPlan.metricDistance(meters))"
                }
                return step.label
            }()
                ?? yogaRunner?.currentStep?.displayName
            let stepEndsAt: Date? = intervalRunner?.currentStep != nil
                ? (intervalRunner?.currentStep?.isDistanceBased == true ? nil : intervalRunner?.stepEndsAt)
                : ((yogaRunner?.currentStep != nil && yogaRunner?.isPaused == false) ? yogaRunner?.stepEndsAt : nil)
            let stepKind = intervalRunner?.currentStep?.kind.rawValue
                ?? (yogaRunner?.currentStep != nil ? "pose" : nil)
            let nextName = intervalRunner?.nextStep?.label
                ?? yogaRunner?.nextStep?.displayName
            let round = intervalRunner?.roundInfo.map { "Round \($0.round) of \($0.total)" }
                ?? yogaRunner.flatMap { runner in
                    runner.currentStep != nil
                        ? "Pose \(min(runner.currentIndex + 1, runner.steps.count)) of \(runner.steps.count)"
                        : nil
                }
            let visibleWorkoutItems = OrderedWorkoutItem.ordered(in: active)
            let isYogaWorkout = !visibleWorkoutItems.isEmpty
                && visibleWorkoutItems.allSatisfy { item in
                    switch item {
                    case .exercise(let exercise): exerciseByID[exercise.exerciseID]?.isYoga == true
                    case .block(let block): block.kind == .yoga
                    }
                }
            let exerciseRows = active.exercises
                .filter { $0.generatedByWorkoutBlockID == nil }
                .map { we in
                    let library = exerciseByID[we.exerciseID]
                    let isCardio = library?.isCardio == true
                    let isYoga = library?.isYoga == true
                    let cardioKind = library?.resolvedCardioKind
                    let session = active.cardioSessions.first { $0.workoutExerciseID == we.id }
                    return WatchExerciseSnapshot(
                        id: we.id,
                        position: we.position,
                        exerciseID: we.exerciseID,
                        name: library?.name ?? "Exercise",
                        isCardio: isCardio || isYoga,
                        isYoga: isYoga ? true : nil,
                        cardioKindRaw: cardioKind?.rawValue,
                        supportsOutdoorRoute: library.map { CardioKind.providesGPSDistance(name: $0.name, equipment: $0.equipment) },
                        supersetGroup: we.supersetGroup,
                        cardioState: (isCardio || isYoga) ? cardioState(of: session) : nil,
                        sets: setSnapshots(for: we, exercise: library)
                    )
                }
            let blockRows = active.blocks.map { block in
                let session = active.cardioSessions.first { $0.workoutBlockID == block.id }
                let conditioningPlan = block.kind == .conditioning
                    ? ConditioningPlan.decode(from: block.planSnapshotJSON)
                    : nil
                let movementNames = conditioningPlan.map { plan in
                    Dictionary(
                        plan.sections.flatMap(\.movements).compactMap { movement in
                            exerciseByID[movement.exerciseID].map { (movement.exerciseID, $0.name) }
                        },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
                return WatchExerciseSnapshot(
                    id: block.id,
                    position: block.position,
                    name: block.kind.title,
                    isCardio: true,
                    isYoga: block.kind == .yoga ? true : nil,
                    workoutBlockKindRaw: block.kind.rawValue,
                    conditioningPlan: conditioningPlan,
                    conditioningProgress: block.kind == .conditioning
                        ? ConditioningProgress.decode(from: block.progressJSON) ?? ConditioningProgress()
                        : nil,
                    conditioningMovementNames: movementNames,
                    cardioState: cardioState(of: session)
                )
            }
            let rootConditioningPlan = ConditioningPlan.decode(from: active.conditioningPlanSnapshotJSON)
            snapshot = WatchWorkoutSnapshot(
                workoutID: active.id,
                title: active.title,
                startedAt: active.startedAt,
                exercises: (exerciseRows + blockRows).sorted {
                    if ($0.position ?? 0) != ($1.position ?? 0) { return ($0.position ?? 0) < ($1.position ?? 0) }
                    return $0.id.uuidString < $1.id.uuidString
                },
                restEndsAt: timer.isRunning ? timer.endsAt : nil,
                restTotalSeconds: timer.isRunning ? timer.totalSeconds : nil,
                restIsMicro: timer.isRunning ? timer.isMicro : nil,
                restLabel: timer.isRunning ? timer.label : nil,
                restOwnerID: timer.isRunning ? timer.ownerID : nil,
                intervalStepName: stepName,
                intervalStepEndsAt: stepEndsAt,
                intervalStepKind: stepKind,
                intervalNextName: nextName,
                intervalRound: round,
                hrZoneTarget: activeZoneTarget,
                isYogaWorkout: isYogaWorkout ? true : nil,
                conditioningPlan: rootConditioningPlan,
                conditioningProgress: rootConditioningPlan == nil
                    ? nil
                    : ConditioningProgress.decode(from: active.conditioningProgressJSON) ?? ConditioningProgress()
            )
        }

        return WatchAppContext(
            workout: snapshot,
            routines: routineSummaries,
            readiness: readiness,
            readinessAction: idleReadiness?.readinessAction,
            readinessDetail: idleReadiness?.readinessDetail,
            unitSuffix: Fmt.unit.suffix,
            distanceUnit: Fmt.distanceUnit,
            hrZoneConfig: HRZoneConfigStore.load()
        )
    }

    private func cardioState(of session: CardioSessionModel?) -> WatchExerciseSnapshot.CardioState {
        guard let session else { return .notStarted }
        if session.endedAt != nil { return .completed }
        return session.liveStartedAt != nil ? .running : .notStarted
    }

    private func setSnapshots(for we: WorkoutExerciseModel, exercise: ExerciseLibraryModel?) -> [WatchSetSnapshot] {
        let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
        let sorted = we.sets.sorted { $0.position < $1.position }
        var workingNumber = 0
        return sorted.map { set in
            let style = SetTypeStyle.of(set.setType)
            if style.numbered { workingNumber += 1 }
            let label = style.numbered ? "\(workingNumber)\(style.badge)" : style.badge
            // Mode-routed: for bodyweight-family sets the number lives in
            // addedWeight/assistanceWeight, not `weight` — reading the raw
            // field showed "—" on the wrist for values the phone displayed.
            return WatchSetSnapshot(
                id: set.id,
                label: label,
                weight: set.modeWeight.map { unit.displayValue(fromKilograms: $0) },
                unitSuffix: unit.suffix,
                weightKg: set.modeWeight,
                reps: set.reps,
                completed: set.completedAt != nil,
                setTypeRaw: set.setType.rawValue,
                weightModeRaw: set.weightMode.rawValue,
                durationSeconds: set.durationSeconds,
                isUnilateral: exercise?.isUnilateral == true || set.isUnilateral,
                miniReps: set.miniReps,
                side2Reps: set.side2Reps,
                side2MiniReps: set.side2MiniReps,
                plannedMiniSetCount: set.plannedMiniSetCount,
                plannedMiniReps: set.plannedMiniReps,
                microRestSeconds: we.microRestSeconds
            )
        }
    }

    // MARK: - Send (phone → watch)

    func sendCommand(_ command: WatchCommand) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let data = WatchWire.encode(command) else { return }
        let payload = [WatchWire.commandKey: data]
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        } else {
            WCSession.default.transferUserInfo(payload)
        }
        #endif
    }

    // MARK: - Handle (watch → phone)

    /// Internal so focused tests can exercise the real Watch command →
    /// SwiftData persistence path without routing through WCSession.
    func handle(_ command: WatchCommand) {
        guard let context = modelContext else { return }
        var activeDescriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        activeDescriptor.fetchLimit = 1
        let active = try? context.fetch(activeDescriptor).first

        switch command {
        case .startRoutine(let routineID):
            guard active == nil else { publishState(policy: .immediate); return }
            let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
            let setupNotes = (try? context.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? []
            let routines = (try? context.fetch(FetchDescriptor<RoutineModel>())) ?? []
            guard let routine = routines.first(where: { $0.id == routineID && $0.deletedAt == nil && $0.archivedAt == nil }) else { return }
            let workout = WorkoutFactory.start(routine: routine, exercises: exercises, setupNotes: setupNotes, in: context)
            beginSession(for: workout, in: context)

        case .startEmpty:
            guard active == nil else { publishState(policy: .immediate); return }
            let workout = WorkoutFactory.startEmpty(in: context)
            beginSession(for: workout, in: context)

        case .toggleSet(let setID, let completed):
            guard let set = fetchSet(setID, in: context) else { return }
            set.completedAt = completed ? Date() : nil
            if completed { HealthMetricsStore.shared.fillBodyweight(set) }
            set.recomputeDerivedMetrics()
            active?.recomputeTotalVolume()
            if completed, let workoutExercise = set.workoutExercise {
                startRestIfNeeded(after: set, in: workoutExercise, active: active)
            }
            try? context.save()
            publishState(policy: .immediate)

        case .updateSet(let setID, let weightKg, let reps):
            guard let set = fetchSet(setID, in: context) else { return }
            // Same mode routing as the phone's set row — a wrist edit on an
            // assisted/added set must land in that mode's field, not `weight`.
            if let weightKg { set.setModeWeight(weightKg) }
            if let reps { set.reps = reps }
            set.recomputeDerivedMetrics()
            active?.recomputeTotalVolume()
            try? context.save()
            publishState(policy: .immediate)

        case .updateStructuredSet(let setID, let update):
            guard let set = fetchSet(setID, in: context), set.setType.isBlockType else { return }
            let previous = WatchStructuredSetProgress(
                activationReps: set.setType == .cluster ? nil : set.reps,
                miniReps: set.miniReps,
                side2ActivationReps: set.setType == .cluster ? nil : set.side2Reps,
                side2MiniReps: set.side2MiniReps
            )
            if let weightKg = update.weightKg { set.setModeWeight(weightKg) }
            set.miniReps = update.progress.miniReps
            set.side2MiniReps = update.progress.side2MiniReps
            if set.setType == .cluster {
                // Cluster `reps` mirrors side 1 only; side 2 is counted from
                // `side2MiniReps` by SetModel's derived-metric policy.
                set.reps = update.progress.miniReps.reduce(0, +)
                set.side2Reps = nil
            } else {
                set.reps = update.progress.activationReps
                set.side2Reps = update.progress.side2ActivationReps
            }
            set.recomputeDerivedMetrics()
            active?.recomputeTotalVolume()

            if structuredEventWasLogged(update, previous: previous),
               let workoutExercise = set.workoutExercise {
                startStructuredMicroRest(
                    after: update,
                    set: set,
                    workoutExercise: workoutExercise
                )
            }
            try? context.save()
            publishState(policy: .immediate)

        case .startSetTimer(let setID, let durationSeconds, let endsAt):
            guard let set = fetchSet(setID, in: context), set.setType == .amrap else { return }
            let duration = max(1, durationSeconds)
            set.durationSeconds = duration
            let remaining = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
            if remaining > 0 {
                let startedAt = endsAt.addingTimeInterval(-TimeInterval(duration))
                RestTimerController.shared.start(
                    seconds: remaining,
                    label: "AMRAP",
                    ownerID: set.id,
                    soundOnEnd: true,
                    endNotification: (title: "Time's up", body: "Log the reps you got."),
                    onComplete: { [weak set] _ in
                        let elapsed = max(1, min(duration, Int(Date.now.timeIntervalSince(startedAt))))
                        set?.durationSeconds = elapsed
                    }
                )
            }
            try? context.save()
            publishState(policy: .immediate)

        case .stopSetTimer(let setID, let elapsedSeconds):
            guard let set = fetchSet(setID, in: context), set.setType == .amrap else { return }
            if RestTimerController.shared.ownerID == set.id {
                RestTimerController.shared.skip()
            }
            set.durationSeconds = max(1, elapsedSeconds)
            try? context.save()
            publishState(policy: .immediate)

        case .startCardio(let workoutExerciseID):
            if let active,
               let block = active.blocks.first(where: { $0.id == workoutExerciseID }) {
                startWorkoutBlock(block, in: active, context: context)
                try? context.save()
                publishState(policy: .immediate)
                break
            }
            guard let session = active?.cardioSessions.first(where: { $0.workoutExerciseID == workoutExerciseID }) else { return }
            guard active?.cardioSessions.contains(where: {
                $0.id != session.id && $0.liveStartedAt != nil && $0.endedAt == nil
            }) != true else { publishState(policy: .immediate); return }
            let now = Date.now
            session.liveStartedAt = now
            session.updatedAt = now
            let workoutExercise = active?.exercises.first { $0.id == workoutExerciseID }
            var library: ExerciseLibraryModel?
            if let exerciseID = workoutExercise?.exerciseID {
                library = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>(predicate: #Predicate { $0.id == exerciseID })))?.first
            }
            CardioGoalAnnouncer.shared.activate(
                sessionID: session.id,
                goal: IntervalPlan.decode(from: workoutExercise?.intervalPlanJSON)?.goal,
                startedAt: now,
                cardioKind: library?.resolvedCardioKind ?? CardioKind.from(modality: session.modality)
            )
            if library.map({ CardioKind.providesGPSDistance(name: $0.name, equipment: $0.equipment) }) == true {
                CardioRouteRecorder.shared.start(session: session)
            }
            try? context.save()
            // A yoga session started from the wrist also starts the guided
            // flow on the phone (execution authority), so cues + pose
            // mirroring work exactly as a phone-started class.
            if session.isYogaSession,
               let we = active?.exercises.first(where: { $0.id == workoutExerciseID }) {
                if let plan = YogaFlowPlan.resolved(for: we, exercise: library), plan.hasSteps {
                    YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: context)
                }
            }
            publishState(policy: .immediate)

        case .completeCardio(let workoutExerciseID):
            if let active,
               let block = active.blocks.first(where: { $0.id == workoutExerciseID }) {
                completeWorkoutBlock(block, in: active, context: context)
                break
            }
            guard let session = active?.cardioSessions.first(where: { $0.workoutExerciseID == workoutExerciseID }),
                  session.endedAt == nil else { return }
            IntervalRunnerHub.shared.stop(for: session.id)
            HRZoneGuard.shared.deactivate()
            PaceGuard.shared.deactivate()
            NotificationScheduler.shared.cancelCardioCues()
            let start = session.liveStartedAt ?? session.startedAt
            let now = Date.now
            let workoutExercise = active?.exercises.first(where: { $0.id == workoutExerciseID })
            var library: ExerciseLibraryModel?
            if let exerciseID = workoutExercise?.exerciseID {
                library = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>(predicate: #Predicate { $0.id == exerciseID })))?.first
            }
            let kind = CardioKind.from(modality: session.modality)
            CardioGoalAnnouncer.shared.activate(
                sessionID: session.id,
                goal: IntervalPlan.decode(from: workoutExercise?.intervalPlanJSON)?.goal,
                startedAt: start,
                cardioKind: library?.resolvedCardioKind ?? kind
            )
            let distanceAtEnd = CardioRouteRecorder.shared.authoritativeLiveDistance(
                for: session.id,
                storedMeters: session.distanceMeters,
                at: now
            )
            let elevationAtEnd = CardioRouteRecorder.shared.recordingSessionID == session.id
                ? CardioRouteRecorder.shared.liveElevationGainMeters
                : session.elevationGainMeters
            session.endedAt = now
            session.durationSeconds = max(1, Int(now.timeIntervalSince(start)))
            if session.isYogaSession {
                YogaFlowRunnerHub.shared.stop(for: session.id)
                YogaSessionCompletion.complete(
                    session: session,
                    workoutExercise: workoutExercise,
                    exercise: library,
                    context: context,
                    endedAt: now,
                    useClockDuration: false
                )
            }
            // Look up the exercise to tell an outdoor run from a treadmill —
            // the stored modality alone can't (both resolve to `.run`).
            let providesGPSDistance = CardioKind.providesGPSDistance(name: library?.name ?? "", equipment: library?.equipment)
            if providesGPSDistance {
                CardioRouteRecorder.shared.stop(session: session, in: context)
            }
            CardioGoalAnnouncer.shared.evaluate(
                sessionID: session.id,
                distanceMeters: distanceAtEnd,
                elapsedSeconds: session.durationSeconds,
                liveActiveEnergyTotalKcal: LiveMetricsHub.shared.liveMetrics?.activeEnergyKcal,
                elevationGainMeters: elevationAtEnd,
                at: now
            )
            CardioGoalAnnouncer.shared.stopLiveUpdates(sessionID: session.id)
            let hadManualIntervalPlan = workoutExercise
                .flatMap { IntervalPlan.decode(from: $0.intervalPlanJSON)?.hasSteps } == true
            try? context.save()
            publishState(policy: .immediate)
            let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: now)
            Task { @MainActor in
                let snap = await HealthService.shared.importSnapshot(from: start, to: now, modality: kind)
                if let hr = snap.avgHR ?? bleStats?.avgHR { session.avgHR = hr }
                if let mx = snap.maxHR ?? bleStats?.maxHR { session.maxHR = mx }
                if let e = snap.activeEnergyKcal { session.activeEnergyKcal = e }
                // Keep the GPS route distance when a route was recorded (the
                // splits are summed from it); only take HealthKit's distance
                // when there's no route to trust.
                if let dist = snap.distanceMeters, providesGPSDistance, session.routePoints.count < 2 {
                    session.distanceMeters = dist
                }
                session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
                try? context.save()
                await CardioSeriesService.finalize(session: session, hadManualIntervalPlan: hadManualIntervalPlan, in: context)
                CardioGoalAnnouncer.shared.finish(
                    sessionID: session.id,
                    distanceMeters: session.distanceMeters ?? distanceAtEnd,
                    durationSeconds: session.durationSeconds,
                    activeEnergyKcal: session.activeEnergyKcal,
                    elevationGainMeters: session.elevationGainMeters ?? elevationAtEnd
                )
            }

        case .liveMetrics(let metrics):
            LiveMetricsHub.shared.updateFromWatch(metrics)
            CardioRouteRecorder.shared.updateWatchDistance(metrics.distanceMeters)
            if let session = active?.cardioSessions.first(where: {
                $0.liveStartedAt != nil && $0.endedAt == nil && $0.deletedAt == nil
            }) {
                if !CardioGoalAnnouncer.shared.isTracking(sessionID: session.id) {
                    let workoutExercise = session.workoutExerciseID.flatMap { id in
                        active?.exercises.first { $0.id == id }
                    }
                    CardioGoalAnnouncer.shared.activate(
                        sessionID: session.id,
                        goal: IntervalPlan.decode(from: workoutExercise?.intervalPlanJSON)?.goal,
                        startedAt: session.liveStartedAt ?? session.startedAt,
                        cardioKind: CardioKind.from(modality: session.modality)
                    )
                }
                CardioGoalAnnouncer.shared.evaluate(
                    sessionID: session.id,
                    liveActiveEnergyTotalKcal: metrics.activeEnergyKcal,
                    at: .now
                )
            }

        case .conditioningEvent(let event):
            guard let active,
                  let plan = ConditioningPlan.decode(from: active.conditioningPlanSnapshotJSON) else { return }
            let current = ConditioningProgress.decode(from: active.conditioningProgressJSON) ?? ConditioningProgress()
            if case .setScore = event.action,
               ConditioningProgressEngine.requiredRoundsRemaining(for: current, plan: plan) > 0 {
                publishState(policy: .immediate)
                return
            }
            let next = ConditioningProgressEngine.apply(event, to: current, plan: plan)
            active.conditioningProgressJSON = next.encodedJSON()
            if next.status == .completed || next.status == .expired {
                active.conditioningResultJSON = ConditioningProgressEngine.result(for: next, plan: plan).encodedJSON()
            }
            try? context.save()
            publishState(policy: .immediate)

        case .conditioningBlockEvent(let blockID, let event):
            guard let active,
                  let block = active.blocks.first(where: { $0.id == blockID && $0.kind == .conditioning }),
                  let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) else { return }
            if case .start = event.action,
               active.cardioSessions.contains(where: {
                   $0.workoutBlockID != blockID
                       && $0.liveStartedAt != nil
                       && $0.endedAt == nil
                       && $0.deletedAt == nil
               }) {
                // The Watch updates optimistically. Re-publish the phone's
                // unchanged source of truth so it cannot keep two timed
                // segments active after this rejected start.
                publishState(policy: .immediate)
                return
            }
            let current = ConditioningProgress.decode(from: block.progressJSON) ?? ConditioningProgress()
            if case .setScore = event.action,
               ConditioningProgressEngine.requiredRoundsRemaining(for: current, plan: plan) > 0 {
                publishState(policy: .immediate)
                return
            }
            let next = ConditioningProgressEngine.apply(event, to: current, plan: plan)
            guard next != current else { return }
            materializeConditioningChanges(
                from: current,
                to: next,
                plan: plan,
                block: block,
                workout: active,
                context: context,
                at: event.timestamp
            )
            block.progressJSON = next.encodedJSON()
            block.resultJSON = ConditioningProgressEngine.result(for: next, plan: plan).encodedJSON()
            block.updatedAt = .now
            if current.status == .ready, next.status != .ready {
                startWorkoutBlock(block, in: active, context: context)
            }
            let explicitlyFinished: Bool
            if case .setScore = event.action {
                explicitlyFinished = true
            } else {
                explicitlyFinished = false
            }
            if explicitlyFinished || next.status == .completed || next.status == .expired {
                completeBlockSession(block, in: active, context: context, endedAt: event.timestamp)
            }
            active.recomputeTotalVolume()
            try? context.save()
            publishState(policy: .immediate)

        case .finishWorkout(let metrics, let savedToHealth):
            guard let active else { return }
            let failure = WorkoutFinisher.finish(
                active,
                in: context,
                liveMetrics: metrics ?? LiveMetricsHub.shared.liveMetrics,
                watchSavedToHealth: savedToHealth
            )
            if failure == nil {
                onWorkoutFinishedFromWatch?()
            } else {
                publishState(policy: .immediate)
            }

        case .discardWorkout:
            guard let active else { return }
            WorkoutFinisher.discard(active, in: context)
            onWorkoutFinishedFromWatch?()

        case .workoutFinished:
            break // phone → watch only
        }
    }

    private func startWorkoutBlock(
        _ block: WorkoutBlockModel,
        in workout: WorkoutModel,
        context: ModelContext
    ) {
        let existingSession = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && ($0.workoutExerciseID == nil || block.kind == .yoga)
        }
        guard workout.cardioSessions.contains(where: {
            $0.id != existingSession?.id && $0.liveStartedAt != nil && $0.endedAt == nil
        }) == false else { return }

        let session = existingSession ?? CardioSessionModel(
            userID: workout.userID,
            workoutBlockID: block.id,
            modality: block.kind == .yoga ? CardioSessionModel.yogaModality : CardioSessionModel.conditioningModality,
            startedAt: .now,
            sourceDevice: block.kind == .yoga ? "watch-yoga" : "watch-conditioning"
        )
        if existingSession == nil {
            context.insert(session)
            workout.cardioSessions.append(session)
        }
        let now = Date.now
        session.startedAt = now
        session.liveStartedAt = now
        session.updatedAt = now

        if block.kind == .conditioning,
           let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) {
            let current = ConditioningProgress.decode(from: block.progressJSON) ?? ConditioningProgress()
            if current.status == .ready {
                block.progressJSON = ConditioningProgressEngine.apply(
                    ConditioningProgressEvent(timestamp: now, action: .start),
                    to: current,
                    plan: plan
                ).encodedJSON()
            }
        } else if block.kind == .yoga,
                  let plan = YogaFlowPlan.decode(from: block.planSnapshotJSON),
                  plan.hasSteps {
            let anchor = ensureYogaAnchor(for: block, in: workout, context: context)
            session.workoutExerciseID = anchor.id
            session.yogaStyleRaw = plan.styleRaw
            YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: context)
        }
        block.updatedAt = now
        Task { await HealthService.shared.requestAuthorizationIfNeeded() }
    }

    private func completeWorkoutBlock(
        _ block: WorkoutBlockModel,
        in workout: WorkoutModel,
        context: ModelContext
    ) {
        if block.kind == .conditioning,
           let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) {
            let current = ConditioningProgress.decode(from: block.progressJSON) ?? ConditioningProgress()
            guard ConditioningProgressEngine.requiredRoundsRemaining(for: current, plan: plan) == 0 else {
                publishState(policy: .immediate)
                return
            }
            let event = ConditioningProgressEvent(action: .setScore(
                rounds: current.fullRounds,
                partialMovementID: nil,
                partialValue: 0,
                load: nil
            ))
            let next = ConditioningProgressEngine.apply(event, to: current, plan: plan)
            block.progressJSON = next.encodedJSON()
            block.resultJSON = ConditioningProgressEngine.result(for: next, plan: plan).encodedJSON()
            completeBlockSession(block, in: workout, context: context, endedAt: event.timestamp)
            try? context.save()
            publishState(policy: .immediate)
            return
        }

        guard let session = workout.cardioSessions.first(where: { $0.workoutBlockID == block.id }),
              session.endedAt == nil else { return }
        let anchor = ensureYogaAnchor(for: block, in: workout, context: context)
        YogaFlowRunnerHub.shared.stop(for: session.id)
        let end = Date.now
        let start = session.liveStartedAt ?? session.startedAt
        let exercise = exercise(for: anchor, in: context)
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: anchor,
            exercise: exercise,
            context: context,
            endedAt: end,
            useClockDuration: true
        )
        block.updatedAt = end
        try? context.save()
        finishBlockHealthSession(session, start: start, end: end, modality: .other, context: context)
        publishState(policy: .immediate)
    }

    private func ensureYogaAnchor(
        for block: WorkoutBlockModel,
        in workout: WorkoutModel,
        context: ModelContext
    ) -> WorkoutExerciseModel {
        if let existing = workout.exercises.first(where: { $0.generatedByWorkoutBlockID == block.id }) {
            existing.yogaFlowJSON = block.planSnapshotJSON
            return existing
        }
        let library = YogaPoseCatalog.sessionExercise(in: context)
        let anchor = WorkoutExerciseModel(
            userID: workout.userID,
            exerciseID: library.id,
            position: block.position,
            yogaFlowJSON: block.planSnapshotJSON,
            generatedByWorkoutBlockID: block.id,
            sets: []
        )
        context.insert(anchor)
        workout.exercises.append(anchor)
        return anchor
    }

    private func completeBlockSession(
        _ block: WorkoutBlockModel,
        in workout: WorkoutModel,
        context: ModelContext,
        endedAt: Date
    ) {
        let session = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && $0.workoutExerciseID == nil
        } ?? CardioSessionModel(
            userID: workout.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: endedAt,
            sourceDevice: "watch-conditioning"
        )
        if session.workout == nil {
            context.insert(session)
            workout.cardioSessions.append(session)
        }
        let start = session.liveStartedAt
            ?? ConditioningProgress.decode(from: block.progressJSON)?.startedAt
            ?? endedAt
        session.startedAt = start
        session.liveStartedAt = start
        session.endedAt = endedAt
        session.durationSeconds = max(1, Int(endedAt.timeIntervalSince(start)))
        block.updatedAt = endedAt
        finishBlockHealthSession(session, start: start, end: endedAt, modality: .other, context: context)
    }

    private func finishBlockHealthSession(
        _ session: CardioSessionModel,
        start: Date,
        end: Date,
        modality: CardioKind,
        context: ModelContext
    ) {
        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        let container = context.container
        Task { @MainActor in
            defer { withExtendedLifetime(container) {} }
            let snapshot = await HealthService.shared.importSnapshot(from: start, to: end, modality: modality)
            if let heartRate = snapshot.avgHR ?? bleStats?.avgHR { session.avgHR = heartRate }
            if let maxHeartRate = snapshot.maxHR ?? bleStats?.maxHR { session.maxHR = maxHeartRate }
            if let energy = snapshot.activeEnergyKcal { session.activeEnergyKcal = energy }
            session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(
                avgHR: session.avgHR,
                durationSeconds: session.durationSeconds
            )
            try? context.save()
            await CardioSeriesService.finalize(session: session, hadManualIntervalPlan: false, in: context)
        }
    }

    private func materializeConditioningChanges(
        from old: ConditioningProgress,
        to new: ConditioningProgress,
        plan: ConditioningPlan,
        block: WorkoutBlockModel,
        workout: WorkoutModel,
        context: ModelContext,
        at date: Date
    ) {
        for movement in plan.sections.flatMap(\.movements) {
            let delta = (new.movementTotals[movement.id] ?? 0) - (old.movementTotals[movement.id] ?? 0)
            guard delta != 0 else { continue }
            let workoutExercise = workout.exercises.first {
                $0.generatedByWorkoutBlockID == block.id && $0.exerciseID == movement.exerciseID
            } ?? {
                let created = WorkoutExerciseModel(
                    userID: workout.userID,
                    exerciseID: movement.exerciseID,
                    position: block.position,
                    generatedByWorkoutBlockID: block.id
                )
                context.insert(created)
                workout.exercises.append(created)
                return created
            }()

            if delta < 0 {
                if let set = workoutExercise.sets
                    .filter({ $0.completedAt != nil })
                    .sorted(by: { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
                    .first {
                    context.delete(set)
                    workoutExercise.sets.removeAll { $0.id == set.id }
                }
                continue
            }

            let library = exercise(for: workoutExercise, in: context)
            if library?.isCardio == true || library?.isYoga == true {
                let session = workout.cardioSessions.first { $0.workoutExerciseID == workoutExercise.id }
                    ?? CardioSessionModel(
                        userID: workout.userID,
                        workoutExerciseID: workoutExercise.id,
                        workoutBlockID: block.id,
                        modality: library?.isYoga == true
                            ? CardioSessionModel.yogaModality
                            : CardioKind.infer(name: library?.name ?? "Cardio", equipment: library?.equipment).rawValue,
                        startedAt: date,
                        endedAt: date,
                        sourceDevice: "watch-conditioning"
                    )
                if session.workout == nil {
                    context.insert(session)
                    workout.cardioSessions.append(session)
                }
                if movement.targetUnit == .seconds { session.durationSeconds = (session.durationSeconds ?? 0) + Int(delta) }
                if movement.targetUnit == .meters { session.distanceMeters = (session.distanceMeters ?? 0) + delta }
                session.endedAt = date
            } else {
                let set = SetModel(
                    userID: workout.userID,
                    position: workoutExercise.sets.count,
                    weightMode: movement.weightMode,
                    reps: movement.targetUnit == .reps ? Int(delta) : nil,
                    durationSeconds: movement.targetUnit == .seconds ? Int(delta) : nil,
                    completedAt: date
                )
                set.setModeWeight(movement.targetLoad)
                context.insert(set)
                workoutExercise.sets.append(set)
            }
        }
    }

    private func beginSession(for workout: WorkoutModel, in context: ModelContext) {
        _ = ReadinessSurfacePublisher.applyCachedStart(to: workout)
        LiveMetricsHub.shared.clearLiveMetrics()
        try? context.save()
        onWorkoutStartedFromWatch?()
        publishState(policy: .immediate)
    }

    private func fetchSet(_ id: UUID, in context: ModelContext) -> SetModel? {
        var d = FetchDescriptor<SetModel>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? context.fetch(d).first
    }

    private func exercise(
        for workoutExercise: WorkoutExerciseModel?,
        in context: ModelContext
    ) -> ExerciseLibraryModel? {
        guard let exerciseID = workoutExercise?.exerciseID else { return nil }
        var descriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Guard micro-rests with the actual state transition so a retried or
    /// duplicated WatchConnectivity packet cannot restart the timer.
    private func structuredEventWasLogged(
        _ update: WatchStructuredSetUpdate,
        previous: WatchStructuredSetProgress
    ) -> Bool {
        switch update.event {
        case .activation:
            return previous.activation(for: update.side) == nil
                && update.progress.activation(for: update.side) != nil
        case .miniSet:
            return update.progress.minis(for: update.side).count
                > previous.minis(for: update.side).count
        case .correction:
            return false
        }
    }

    /// Reconstruct the absolute wrist-side micro-rest. Offline commands that
    /// arrive after the interval expired still persist the reps but never
    /// start a stale countdown on the phone.
    private func startStructuredMicroRest(
        after update: WatchStructuredSetUpdate,
        set: SetModel,
        workoutExercise: WorkoutExerciseModel
    ) {
        let seconds = workoutExercise.microRestSeconds
            ?? set.setType.defaultMicroRestSeconds
            ?? 15
        let endsAt = update.occurredAt.addingTimeInterval(TimeInterval(seconds))
        let remaining = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
        guard remaining > 0, set.completedAt == nil else { return }
        let nextMini = update.progress.minis(for: update.side).count + 1
        let label = set.isUnilateral
            ? "S\(update.side) mini-set \(nextMini)"
            : "Mini-set \(nextMini)"
        RestTimerController.shared.start(
            seconds: remaining,
            label: label,
            micro: true,
            ownerID: set.id
        )
    }

    private func startRestIfNeeded(after set: SetModel, in workoutExercise: WorkoutExerciseModel, active: WorkoutModel?) {
        guard !hasPendingDropSet(after: set, in: workoutExercise) else { return }
        guard let group = workoutExercise.supersetGroup else {
            startRest(after: set, in: workoutExercise)
            return
        }

        let sets = workoutExercise.sets.sorted { $0.position < $1.position }
        guard let roundIndex = supersetRoundIndex(for: set, in: sets) else { return }
        let groupMembers = (active?.exercises ?? []).filter { $0.supersetGroup == group }.sorted { $0.position < $1.position }
        let roundComplete = groupMembers.allSatisfy { member in
            let memberSets = member.sets.sorted { $0.position < $1.position }
            guard roundIndex < memberSets.count else { return true }
            return setAndDropChainComplete(at: roundIndex, in: memberSets)
        }
        guard roundComplete else { return }
        startRest(after: set, in: workoutExercise, label: "\(SupersetUI.label(for: group)) rest")
    }

    private func hasPendingDropSet(after set: SetModel, in workoutExercise: WorkoutExerciseModel) -> Bool {
        let sets = workoutExercise.sets.sorted { $0.position < $1.position }
        guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return false }
        let next = index + 1
        guard next < sets.count, sets[next].setType == .drop else { return false }
        return sets[next].completedAt == nil
    }

    private func supersetRoundIndex(for set: SetModel, in sets: [SetModel]) -> Int? {
        guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return nil }
        guard set.setType == .drop else { return index }
        return sets[..<index].lastIndex { $0.setType != .drop }
    }

    private func setAndDropChainComplete(at index: Int, in sets: [SetModel]) -> Bool {
        guard index < sets.count, sets[index].completedAt != nil else { return false }
        var next = index + 1
        while next < sets.count, sets[next].setType == .drop {
            guard sets[next].completedAt != nil else { return false }
            next += 1
        }
        return true
    }

    private func startRest(after set: SetModel, in workoutExercise: WorkoutExerciseModel, label: String? = nil) {
        let fallback = set.setType == .drop ? SetType.working.defaultRestSeconds : set.setType.defaultRestSeconds
        let seconds = workoutExercise.restSeconds ?? fallback
        guard let seconds, seconds > 0 else { return }
        RestTimerController.shared.start(seconds: seconds, label: label ?? SetTypeStyle.of(set.setType).label)
    }
}

#if canImport(WatchConnectivity)
extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            refresh()
            publishState()
            // Pick up whatever HR the watch last published while we were
            // inactive/not-yet-launched — the always-latest fallback channel
            // (see WatchStore.send) means this is never a stale replay.
            self.applyReceivedLiveMetrics(session.receivedApplicationContext)
        }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            refresh()
            publishState()
        }
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refresh() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[WatchWire.commandKey] as? Data,
              let command = WatchWire.decode(WatchCommand.self, from: data) else { return }
        Task { @MainActor in self.handle(command) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchWire.commandKey] as? Data,
              let command = WatchWire.decode(WatchCommand.self, from: data) else { return }
        Task { @MainActor in self.handle(command) }
    }
    /// The watch's always-latest HR fallback (see `WatchWire.liveMetricsKey`):
    /// delivered via application context so a reading from while the watch
    /// display was off still reaches us the moment the phone reconnects,
    /// instead of waiting for the next `sendMessage` after wrist-raise.
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applyReceivedLiveMetrics(applicationContext) }
    }
    @MainActor
    private func applyReceivedLiveMetrics(_ payload: [String: Any]) {
        guard let data = payload[WatchWire.liveMetricsKey] as? Data,
              let command = WatchWire.decode(WatchCommand.self, from: data),
              case .liveMetrics(let metrics) = command else { return }
        LiveMetricsHub.shared.updateFromWatch(metrics)
        CardioRouteRecorder.shared.updateWatchDistance(metrics.distanceMeters)
    }
}
#endif
