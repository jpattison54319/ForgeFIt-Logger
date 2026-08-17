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

    /// Isolated transactions commit outside the long-lived UI context. Read
    /// their Watch snapshot through a fresh context so a cached relationship
    /// cannot briefly republish the pre-commit state.
    func publishDurableState() {
        interactionPublisher.cancel()
        publishStateNow(usingFreshContext: true)
    }

    private func publishStateNow(usingFreshContext: Bool = false) {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              let context = modelContext else { return }
        refresh()
        guard isWatchAppInstalled || WCSession.default.isReachable else { return }
        let readContext: ModelContext
        if usingFreshContext {
            readContext = ModelContext(context.container)
            readContext.autosaveEnabled = false
        } else {
            readContext = context
        }
        guard let data = WatchWire.encode(buildContext(in: readContext)) else { return }
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
        if active != nil {
            // The watch is showing the active workout. Routine alternation and
            // completed-history scans are unrelated until that workout closes.
            routineSummaries = []
        } else if let routineSummaryCache {
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
            WorkoutFactory.start(
                routine: routine,
                exercises: exercises,
                setupNotes: setupNotes,
                in: context,
                onCommit: { [weak self] workout in
                    self?.beginSession(for: workout, in: context)
                }
            )

        case .startEmpty:
            guard active == nil else { publishState(policy: .immediate); return }
            WorkoutFactory.startEmpty(
                in: context,
                onCommit: { [weak self] workout in
                    self?.beginSession(for: workout, in: context)
                }
            )

        case .toggleSet(let setID, let completed):
            guard let set = fetchSet(setID, in: context) else { return }
            set.completedAt = completed ? Date() : nil
            if completed { HealthMetricsStore.shared.fillBodyweight(set) }
            set.recomputeDerivedMetrics()
            active?.recomputeTotalVolume()
            let completedExercise = completed ? set.workoutExercise : nil
            context.saveUserChanges { [weak self] in
                if let self, let workoutExercise = completedExercise {
                    self.startRestIfNeeded(after: set, in: workoutExercise, active: active)
                }
                self?.publishState(policy: .immediate)
            }

        case .updateSet(let setID, let weightKg, let reps):
            guard let set = fetchSet(setID, in: context) else { return }
            // Same mode routing as the phone's set row — a wrist edit on an
            // assisted/added set must land in that mode's field, not `weight`.
            if let weightKg { set.setModeWeight(weightKg) }
            if let reps { set.reps = reps }
            set.recomputeDerivedMetrics()
            active?.recomputeTotalVolume()
            context.saveUserChanges { [weak self] in
                self?.publishState(policy: .immediate)
            }

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

            let restExercise = structuredEventWasLogged(update, previous: previous)
                ? set.workoutExercise
                : nil
            context.saveUserChanges { [weak self] in
                if let self, let workoutExercise = restExercise {
                    self.startStructuredMicroRest(
                        after: update,
                        set: set,
                        workoutExercise: workoutExercise
                    )
                }
                self?.publishState(policy: .immediate)
            }

        case .startSetTimer(let setID, let durationSeconds, let endsAt):
            guard let set = fetchSet(setID, in: context), set.setType == .amrap else { return }
            let duration = max(1, durationSeconds)
            let durationBeforeStart = set.durationSeconds
            let setID = set.id
            let remaining = max(0, Int(endsAt.timeIntervalSinceNow.rounded(.up)))
            PersistentChangeSaveCenter.shared.perform({ [weak self] in
                set.durationSeconds = duration
                do {
                    try context.save()
                } catch {
                    set.durationSeconds = durationBeforeStart
                    self?.publishState(policy: .immediate)
                    throw error
                }
            }, onSuccess: { [weak self] in
                if remaining > 0 {
                    let startedAt = endsAt.addingTimeInterval(-TimeInterval(duration))
                    RestTimerController.shared.start(
                        seconds: remaining,
                        label: "AMRAP",
                        ownerID: setID,
                        soundOnEnd: true,
                        endNotification: (title: "Time's up", body: "Log the reps you got."),
                        onComplete: { [weak self] _ in
                            let elapsed = max(1, min(duration, Int(Date.now.timeIntervalSince(startedAt))))
                            guard let self,
                                  let context = self.modelContext,
                                  let set = self.fetchSet(setID, in: context) else { return }
                            set.durationSeconds = elapsed
                            context.saveUserChanges {
                                self.publishState(policy: .immediate)
                            }
                        }
                    )
                }
                self?.publishState(policy: .immediate)
            })

        case .stopSetTimer(let setID, let elapsedSeconds):
            guard let set = fetchSet(setID, in: context), set.setType == .amrap else { return }
            let durationBeforeStop = set.durationSeconds
            let elapsed = max(1, elapsedSeconds)
            PersistentChangeSaveCenter.shared.perform({ [weak self] in
                set.durationSeconds = elapsed
                do {
                    try context.save()
                } catch {
                    set.durationSeconds = durationBeforeStop
                    self?.publishState(policy: .immediate)
                    throw error
                }
            }, onSuccess: { [weak self] in
                if RestTimerController.shared.ownerID == set.id {
                    RestTimerController.shared.skip(reportElapsedTime: false)
                }
                self?.publishState(policy: .immediate)
            })

        case .startCardio(let workoutExerciseID):
            if let active,
               let block = active.blocks.first(where: { $0.id == workoutExerciseID }) {
                persistWorkoutBlockStart(
                    blockID: block.id,
                    workoutID: active.id,
                    callerContext: context
                )
                break
            }
            guard let session = active?.cardioSessions.first(where: { $0.workoutExerciseID == workoutExerciseID }) else { return }
            guard active?.cardioSessions.contains(where: {
                $0.id != session.id && $0.liveStartedAt != nil && $0.endedAt == nil
            }) != true else { publishState(policy: .immediate); return }
            let now = Date.now
            let workoutExercise = active?.exercises.first { $0.id == workoutExerciseID }
            var library: ExerciseLibraryModel?
            if let exerciseID = workoutExercise?.exerciseID {
                library = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>(predicate: #Predicate { $0.id == exerciseID })))?.first
            }
            CardioSessionStartPersistence.perform(
                session: session,
                startedAt: now,
                resetsStartedAt: false,
                context: context,
                onFailure: { [weak self] in self?.publishState(policy: .immediate) },
                onCommit: { [weak self] in
                CardioGoalAnnouncer.shared.activate(
                    sessionID: session.id,
                    goal: IntervalPlan.decode(from: workoutExercise?.intervalPlanJSON)?.goal,
                    startedAt: now,
                    cardioKind: library?.resolvedCardioKind ?? CardioKind.from(modality: session.modality)
                )
                if library.map({ CardioKind.providesGPSDistance(name: $0.name, equipment: $0.equipment) }) == true {
                    CardioRouteRecorder.shared.start(session: session)
                }
                // A yoga session started from the wrist also starts the guided
                // flow on the phone (execution authority), so cues + pose
                // mirroring work exactly as a phone-started class.
                if session.isYogaSession,
                   let we = active?.exercises.first(where: { $0.id == workoutExerciseID }),
                   let plan = YogaFlowPlan.resolved(for: we, exercise: library),
                   plan.hasSteps {
                    YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: context)
                }
                self?.publishState(policy: .immediate)
            })

        case .completeCardio(let workoutExerciseID):
            if let active,
               let block = active.blocks.first(where: { $0.id == workoutExerciseID }) {
                completeWorkoutBlock(block, in: active, context: context)
                break
            }
            guard let session = active?.cardioSessions.first(where: { $0.workoutExerciseID == workoutExerciseID }),
                  session.endedAt == nil else { return }
            let start = session.liveStartedAt ?? session.startedAt
            let now = Date.now
            let workoutExercise = active?.exercises.first(where: { $0.id == workoutExerciseID })
            var library: ExerciseLibraryModel?
            if let exerciseID = workoutExercise?.exerciseID {
                library = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>(predicate: #Predicate { $0.id == exerciseID })))?.first
            }
            let kind = CardioKind.from(modality: session.modality)
            let distanceAtEnd = CardioRouteRecorder.shared.authoritativeLiveDistance(
                for: session.id,
                storedMeters: session.distanceMeters,
                at: now
            )
            let elevationAtEnd = CardioRouteRecorder.shared.recordingSessionID == session.id
                ? CardioRouteRecorder.shared.liveElevationGainMeters
                : session.elevationGainMeters
            let completingYoga = session.isYogaSession
            if completingYoga {
                YogaFlowRunnerHub.shared.captureCheckpointForTerminalAttempt(sessionID: session.id)
            }
            // Look up the exercise to tell an outdoor run from a treadmill —
            // the stored modality alone can't (both resolve to `.run`).
            let providesGPSDistance = CardioKind.providesGPSDistance(name: library?.name ?? "", equipment: library?.equipment)
            let hadManualIntervalPlan = workoutExercise
                .flatMap { IntervalPlan.decode(from: $0.intervalPlanJSON)?.hasSteps } == true
            let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: now)
            CardioSessionTerminalPersistence.perform(
                container: context.container,
                sessionID: session.id,
                endedAt: now,
                completesYoga: completingYoga,
                useClockDuration: true,
                stagesRoute: providesGPSDistance
            ) { [weak self] outcome in
                IntervalRunnerHub.shared.stop(for: outcome.sessionID)
                HRZoneGuard.shared.deactivate()
                PaceGuard.shared.deactivate()
                NotificationScheduler.shared.cancelCardioCues()
                if providesGPSDistance {
                    CardioRouteRecorder.shared.cancel(sessionID: outcome.sessionID)
                }
                if completingYoga {
                    YogaFlowRunnerHub.shared.stop(for: outcome.sessionID, clearCheckpoint: true)
                }
                CardioGoalAnnouncer.shared.activate(
                    sessionID: outcome.sessionID,
                    goal: IntervalPlan.decode(from: workoutExercise?.intervalPlanJSON)?.goal,
                    startedAt: outcome.start,
                    cardioKind: library?.resolvedCardioKind ?? kind
                )
                CardioGoalAnnouncer.shared.evaluate(
                    sessionID: outcome.sessionID,
                    distanceMeters: outcome.distanceMeters ?? distanceAtEnd,
                    elapsedSeconds: outcome.durationSeconds,
                    liveActiveEnergyTotalKcal: LiveMetricsHub.shared.liveMetrics?.activeEnergyKcal,
                    elevationGainMeters: outcome.elevationGainMeters ?? elevationAtEnd,
                    at: outcome.end
                )
                CardioGoalAnnouncer.shared.stopLiveUpdates(sessionID: outcome.sessionID)
                DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
                    .init(
                        sessionID: outcome.sessionID,
                        start: outcome.start,
                        end: outcome.end,
                        modality: kind,
                        fallbackAvgHR: bleStats?.avgHR,
                        fallbackMaxHR: bleStats?.maxHR,
                        importsDistance: providesGPSDistance,
                        providesGPSDistance: providesGPSDistance,
                        hadManualIntervalPlan: hadManualIntervalPlan
                    ),
                    container: context.container
                )
                CardioGoalAnnouncer.shared.finish(
                    sessionID: outcome.sessionID,
                    distanceMeters: outcome.distanceMeters ?? distanceAtEnd,
                    durationSeconds: outcome.durationSeconds,
                    activeEnergyKcal: outcome.activeEnergyKcal,
                    elevationGainMeters: outcome.elevationGainMeters ?? elevationAtEnd
                )
                self?.publishDurableState()
            }

        case .liveMetrics(let metrics):
            guard WatchLiveMetricsAttributionPolicy.mayApply(
                metricsWorkoutID: metrics.workoutID,
                activeWorkoutID: active?.id
            ) else { return }
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
                  ConditioningPlan.decode(from: active.conditioningPlanSnapshotJSON) != nil else { return }
            ConditioningEventPersistence.perform(
                container: context.container,
                workoutID: active.id,
                blockID: nil,
                event: event,
                sourceDevice: "watch-conditioning",
                distanceSource: .watchInput
            ) { [weak self] _ in
                self?.publishDurableState()
            }

        case .conditioningBlockEvent(let blockID, let event):
            guard let active,
                  let block = active.blocks.first(where: { $0.id == blockID && $0.kind == .conditioning }),
                  ConditioningPlan.decode(from: block.planSnapshotJSON) != nil else { return }
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
            persistConditioningBlockEvent(
                blockID: blockID,
                workoutID: active.id,
                event: event,
                callerContext: context
            )

        case .finishWorkout(let workoutID, let metrics, let savedToHealth):
            // Terminal commands are only honored for the exact workout they
            // name. A nil ID is the legacy pre-binding wire form; both nil and
            // mismatched IDs are dropped. The authoritative snapshot is then
            // re-published so a watch that cleared itself on a stale command
            // converges instead of staying misleading.
            guard let active,
                  WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: workoutID, activeWorkoutID: active.id)
            else {
                publishState(policy: .immediate)
                return
            }
            let failure = WorkoutFinisher.finish(
                workoutID: active.id,
                in: context,
                liveMetrics: metrics ?? LiveMetricsHub.shared.liveMetrics,
                watchSavedToHealth: savedToHealth
            )
            if failure == nil {
                onWorkoutFinishedFromWatch?()
            } else {
                publishState(policy: .immediate)
            }

        case .discardWorkout(let workoutID):
            guard let active,
                  WatchTerminalCommandPolicy.shouldExecute(carriedWorkoutID: workoutID, activeWorkoutID: active.id)
            else {
                publishState(policy: .immediate)
                return
            }
            if WorkoutFinisher.discard(workoutID: active.id, in: context) == nil {
                onWorkoutFinishedFromWatch?()
            } else {
                // The terminal save rolled the tombstone back. Send the
                // authoritative active workout back to a watch that may have
                // optimistically cleared its local session.
                publishState(policy: .immediate)
            }

        case .workoutFinished:
            break // phone → watch only
        }
    }

    /// Wrist starts run in their own transaction so a failed save cannot
    /// leave the phone's card looking active without its guided runtime. The
    /// global Retry recreates the isolated context and repeats the same IDs.
    private func persistWorkoutBlockStart(
        blockID: UUID,
        workoutID: UUID,
        callerContext: ModelContext
    ) {
        var committedSessionID: UUID?
        PersistentChangeSaveCenter.shared.perform({
            let transaction = ModelContext(callerContext.container)
            transaction.autosaveEnabled = false
            guard let workout = try transaction.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { $0.id == workoutID }
            )).first,
            let block = try transaction.fetch(FetchDescriptor<WorkoutBlockModel>(
                predicate: #Predicate { $0.id == blockID }
            )).first,
            let session = self.startWorkoutBlock(block, in: workout, context: transaction) else {
                committedSessionID = nil
                return
            }
            do {
                try transaction.save()
                committedSessionID = session.id
            } catch {
                transaction.rollback()
                throw error
            }
        }, onSuccess: { [weak self] in
            guard let self,
                  let committedSessionID,
                  let block = try? callerContext.fetch(FetchDescriptor<WorkoutBlockModel>(
                    predicate: #Predicate { $0.id == blockID }
                  )).first,
                  let session = try? callerContext.fetch(FetchDescriptor<CardioSessionModel>(
                    predicate: #Predicate { $0.id == committedSessionID }
                  )).first else {
                self?.publishState(policy: .immediate)
                return
            }
            self.beginWorkoutBlockRuntime(block, session: session, context: callerContext)
            self.publishState(policy: .immediate)
        })
    }

    /// Conditioning progress, materialized logs, session start/end, and the
    /// block result are one atomic wrist action. Building them in an isolated
    /// context means a failed save leaves the caller's active model untouched;
    /// Retry replays the same block/event IDs before any runtime or Health work.
    private func persistConditioningBlockEvent(
        blockID: UUID,
        workoutID: UUID,
        event: ConditioningProgressEvent,
        callerContext: ModelContext
    ) {
        ConditioningEventPersistence.perform(
            container: callerContext.container,
            workoutID: workoutID,
            blockID: blockID,
            event: event,
            sourceDevice: "watch-conditioning",
            distanceSource: .watchInput
        ) { [weak self] outcome in
            guard let self else { return }
            // The long-lived UI context can retain its pre-transaction graph.
            // Resolve every runtime/Health model from a fresh context so the
            // side effects are driven by the exact durable commit.
            let readContext = ModelContext(callerContext.container)
            readContext.autosaveEnabled = false
            guard let committedBlock = try? readContext.fetch(FetchDescriptor<WorkoutBlockModel>(
                predicate: #Predicate { $0.id == blockID }
            )).first,
            ConditioningProgress.decode(from: committedBlock.progressJSON) == outcome.progress else {
                self.publishDurableState()
                return
            }
            if let startedSessionID = outcome.startedSessionID,
               startedSessionID != outcome.completedSessionID,
               let startedSession = try? readContext.fetch(FetchDescriptor<CardioSessionModel>(
                   predicate: #Predicate { $0.id == startedSessionID }
               )).first,
               startedSession.liveStartedAt != nil,
               startedSession.endedAt == nil {
                Task { await HealthService.shared.requestAuthorizationIfNeeded() }
            }
            if let completedSessionID = outcome.completedSessionID {
                if let session = try? readContext.fetch(FetchDescriptor<CardioSessionModel>(
                   predicate: #Predicate { $0.id == completedSessionID }
                )).first {
                    self.finishBlockHealthSession(
                        session,
                        start: session.liveStartedAt ?? session.startedAt,
                        end: session.endedAt ?? event.timestamp,
                        modality: .other,
                        context: readContext
                    )
                }
            }
            self.publishDurableState()
        }
    }

    @discardableResult
    private func startWorkoutBlock(
        _ block: WorkoutBlockModel,
        in workout: WorkoutModel,
        context: ModelContext
    ) -> CardioSessionModel? {
        let existingSession = workout.cardioSessions.first {
            $0.workoutBlockID == block.id && ($0.workoutExerciseID == nil || block.kind == .yoga)
        }
        guard workout.cardioSessions.contains(where: {
            $0.id != existingSession?.id && $0.liveStartedAt != nil && $0.endedAt == nil
        }) == false else { return nil }

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
        }
        block.updatedAt = now
        return session
    }

    private func beginWorkoutBlockRuntime(
        _ block: WorkoutBlockModel,
        session: CardioSessionModel,
        context: ModelContext
    ) {
        Task { await HealthService.shared.requestAuthorizationIfNeeded() }
        guard block.kind == .yoga,
              let plan = YogaFlowPlan.decode(from: block.planSnapshotJSON),
              plan.hasSteps,
              session.workoutExerciseID != nil else { return }
        YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: context)
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
            persistConditioningBlockEvent(
                blockID: block.id,
                workoutID: workout.id,
                event: event,
                callerContext: context
            )
            return
        }

        guard let session = workout.cardioSessions.first(where: { $0.workoutBlockID == block.id }),
              session.endedAt == nil else { return }
        YogaFlowRunnerHub.shared.captureCheckpointForTerminalAttempt(sessionID: session.id)
        let end = Date.now
        let start = session.liveStartedAt ?? session.startedAt
        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        CardioSessionTerminalPersistence.perform(
            container: context.container,
            sessionID: session.id,
            blockID: block.id,
            endedAt: end,
            completesYoga: true,
            useClockDuration: true,
            stagesRoute: false
        ) { [weak self] outcome in
            YogaFlowRunnerHub.shared.stop(for: outcome.sessionID, clearCheckpoint: true)
            DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
                .init(
                    sessionID: outcome.sessionID,
                    start: outcome.start,
                    end: outcome.end,
                    modality: .other,
                    fallbackAvgHR: bleStats?.avgHR,
                    fallbackMaxHR: bleStats?.maxHR,
                    importsDistance: false,
                    providesGPSDistance: false,
                    hadManualIntervalPlan: false
                ),
                container: context.container
            )
            self?.publishDurableState()
        }
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

    private func finishBlockHealthSession(
        _ session: CardioSessionModel,
        start: Date,
        end: Date,
        modality: CardioKind,
        context: ModelContext
    ) {
        let bleStats = LiveMetricsHub.shared.bleWindowStats(from: start, to: end)
        DeferredWorkoutEnrichmentCoordinator.shared.scheduleSession(
            .init(
                sessionID: session.id,
                start: start,
                end: end,
                modality: modality,
                fallbackAvgHR: bleStats?.avgHR,
                fallbackMaxHR: bleStats?.maxHR,
                importsDistance: false,
                providesGPSDistance: false,
                hadManualIntervalPlan: false
            ),
            container: context.container
        )
    }

    private func beginSession(for workout: WorkoutModel, in context: ModelContext) {
        _ = ReadinessSurfacePublisher.applyCachedStart(to: workout)
        LiveMetricsHub.shared.clearLiveMetrics()
        context.saveUserChanges { [weak self] in
            self?.onWorkoutStartedFromWatch?()
            self?.publishState(policy: .immediate)
        }
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
        guard let roundIndex = SupersetRoundPolicy.logicalRoundIndex(
            for: set.id,
            in: sets.map(\.supersetProgress)
        ) else { return }
        let groupMembers = (active?.exercises ?? []).filter { $0.supersetGroup == group }.sorted { $0.position < $1.position }
        let roundComplete = groupMembers.allSatisfy { member in
            let memberSets = member.sets.sorted { $0.position < $1.position }
            return SupersetRoundPolicy.isRoundSatisfied(
                roundIndex,
                in: memberSets.map(\.supersetProgress)
            )
        }
        guard roundComplete else { return }
        startRest(after: set, in: workoutExercise, label: "\(SupersetUI.label(for: group)) rest")
    }

    private func hasPendingDropSet(after set: SetModel, in workoutExercise: WorkoutExerciseModel) -> Bool {
        let sets = workoutExercise.sets.sorted { $0.position < $1.position }
        return SupersetRoundPolicy.hasPendingDrop(
            after: set.id,
            in: sets.map(\.supersetProgress)
        )
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
              case .liveMetrics = command else { return }
        // Route the coalesced application-context fallback through the exact
        // same workout-identity gate and cardio side effects as the immediate
        // message channel. Otherwise a final packet from workout A can arrive
        // after B starts and silently become B's HR, energy, or distance.
        handle(command)
    }
}
#endif
