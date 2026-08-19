import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// Cardio modalities offered as quick-starts.
enum CardioModality: String, CaseIterable, Identifiable {
    case run, cycle, row, walk

    var id: String { rawValue }
    // Titles name the exact exercise the tile launches — no aspirational
    // "Zone 2" branding, which would imply a heart-rate lock the quick-start
    // never configures.
    var title: String {
        switch self {
        case .run: "Outdoor Run"
        case .cycle: "Indoor Bike"
        case .row: "Row"
        case .walk: "Treadmill Walk"
        }
    }
    var systemImage: String {
        switch self {
        case .run: "figure.run"
        case .cycle: "figure.indoor.cycle"
        case .row: "figure.rower"
        case .walk: "figure.walk"
        }
    }
    var exerciseID: UUID? {
        switch self {
        case .run: GlobalExerciseLibrary.outdoorRunID
        case .cycle: GlobalExerciseLibrary.indoorCycleID
        case .row: GlobalExerciseLibrary.rowErgID
        case .walk: GlobalExerciseLibrary.treadmillWalkID
        }
    }
}

/// Central place to create workout sessions so every entry point (Home quick
/// start, the Workout tab, cardio tiles) builds identical, consistent data.
@MainActor
enum WorkoutFactory {

    enum PersistenceError: LocalizedError {
        case committedWorkoutUnavailable

        var errorDescription: String? {
            "The workout was saved, but ForgeFit couldn't open it. Try again."
        }
    }

    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    /// Workout creation happens in an isolated context. A failed graph can
    /// therefore never leak into the app's shared context and hitch a ride on
    /// an unrelated later save. UI/runtime effects run only after the durable
    /// row resolves back into the caller's context.
    private static func commit(
        _ workout: WorkoutModel,
        from persistenceContext: ModelContext,
        into sourceContext: ModelContext,
        saveCenter: PersistentChangeSaveCenter,
        save: @escaping SaveOperation,
        onCommit: @escaping @MainActor (WorkoutModel) -> Void
    ) -> WorkoutModel? {
        var committedWorkout: WorkoutModel?
        let workoutID = workout.id
        saveCenter.perform({
            try save(persistenceContext)
            committedWorkout = try sourceContext.fetch(
                FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == workoutID })
            ).first
            guard committedWorkout != nil else {
                throw PersistenceError.committedWorkoutUnavailable
            }
        }, onSuccess: {
            if let committedWorkout { onCommit(committedWorkout) }
        })
        return committedWorkout
    }

    @discardableResult
    static func startEmpty(
        in context: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (WorkoutModel) -> Void
    ) -> WorkoutModel? {
        let persistenceContext = ModelContext(context.container)
        persistenceContext.autosaveEnabled = false
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Workout",
            sourceDevice: "iphone"
        )
        persistenceContext.insert(workout)
        return commit(
            workout,
            from: persistenceContext,
            into: context,
            saveCenter: saveCenter ?? .shared,
            save: save,
            onCommit: onCommit
        )
    }

    @discardableResult
    static func start(
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        setupNotes: [UserExerciseNoteModel] = [],
        in context: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        prepare: @escaping @MainActor (WorkoutModel, ModelContext) -> Void = { _, _ in },
        onCommit: @escaping @MainActor (WorkoutModel) -> Void
    ) -> WorkoutModel? {
        let persistenceContext = ModelContext(context.container)
        persistenceContext.autosaveEnabled = false
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routine.id,
            title: routine.name,
            sourceDevice: "iphone"
        )
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolvedSetupNotes = setupNotes + ((try? persistenceContext.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? [])
        let effortPreferences = WorkoutEffortPolicy.current()
        var cardioSessions: [CardioSessionModel] = []
        var workoutBlocks = routine.blocks.map { routineBlock in
            WorkoutBlockModel(
                userID: workout.userID,
                kind: routineBlock.kind,
                position: routineBlock.position,
                planSnapshotJSON: routineBlock.planJSON,
                progressJSON: routineBlock.kind == .conditioning ? ConditioningProgress().encodedJSON() : nil,
                sourceRoutineBlockID: routineBlock.id
            )
        }

        // Legacy whole-routine conditioning becomes one first-class block in
        // newly started workouts. The source routine remains untouched until
        // the user explicitly saves it from the editor.
        let usesLegacyConditioning = routine.conditioningPlanJSON != nil
            && !routine.blocks.contains { $0.kind == .conditioning }
        let legacyConditioningPlan = usesLegacyConditioning
            ? ConditioningPlan.decode(from: routine.conditioningPlanJSON)
            : nil
        let legacyConditioningMovementIDs = Set(
            legacyConditioningPlan?.sections.flatMap(\.movements).map(\.exerciseID) ?? []
        )
        if usesLegacyConditioning, let planJSON = routine.conditioningPlanJSON {
            workoutBlocks.append(WorkoutBlockModel(
                userID: workout.userID,
                kind: .conditioning,
                position: routine.exercises
                    .filter { legacyConditioningMovementIDs.contains($0.exerciseID) }
                    .map(\.position).min()
                    ?? routine.exercises.count,
                planSnapshotJSON: planJSON,
                progressJSON: ConditioningProgress().encodedJSON()
            ))
        }

        // Legacy Yoga Session exercise rows project into real blocks at the
        // same visible position. Poses stay in the flow plan, not the general
        // exercise sequence.
        for routineExercise in routine.exercises {
            guard !(usesLegacyConditioning && legacyConditioningMovementIDs.contains(routineExercise.exerciseID)),
                  let exercise = exerciseByID[routineExercise.exerciseID], exercise.isYoga else { continue }
            let flow = YogaFlowPlan.decode(from: routineExercise.yogaFlowJSON)
                ?? (YogaPoseCatalog.isSessionExercise(exercise) ? nil : .singlePose(from: exercise))
            workoutBlocks.append(WorkoutBlockModel(
                userID: workout.userID,
                kind: .yoga,
                position: routineExercise.position,
                planSnapshotJSON: flow?.encodedJSON(),
                sourceRoutineBlockID: nil
            ))
        }

        workout.blocks = workoutBlocks
        for block in workoutBlocks {
            cardioSessions.append(makeBlockSession(for: block, workoutStartedAt: workout.startedAt))
        }

        workout.exercises = routine.exercises
            .filter { routineExercise in
                if usesLegacyConditioning,
                   legacyConditioningMovementIDs.contains(routineExercise.exerciseID) {
                    return false
                }
                return exerciseByID[routineExercise.exerciseID]?.isYoga != true
            }
            .sorted { $0.position < $1.position }
            .map { routineExercise in
                let exercise = exerciseByID[routineExercise.exerciseID]
                let setupNote = resolvedSetupNotes
                    .filter {
                        $0.exerciseID == routineExercise.exerciseID
                            && $0.userID == ForgeFitDemo.userID
                            && ExerciseNotePolicy.authoredText($0.note) != nil
                    }
                    .max { $0.updatedAt < $1.updatedAt }
                let routineNote = ExerciseNotePolicy.authoredText(routineExercise.notes)
                // Cardio exercises log as sessions, not set rows. Yoga now
                // lives in first-class blocks and is filtered above.
                let isSessionBased = exercise?.isCardio == true
                // The set must carry the exercise's weight mode, and the
                // routine target must land in that mode's field — a target
                // seeded into `weight` on a bodyweight-family set is invisible
                // to the input row and, worse, an `.external` default makes
                // tonnage treat the raw number as the lifted load (assistance
                // × reps for assisted work) instead of the effective load.
                let weightMode = exercise?.defaultWeightMode ?? .external
                let pendingSets: [SetModel] = isSessionBased ? [] : routineExercise.sets
                    .sorted { $0.position < $1.position }
                    .map { target in
                        let effort = WorkoutEffortPolicy.initialEffort(
                            setType: target.setType,
                            targetRPE: target.targetRPE,
                            targetRIR: target.targetRIR,
                            preferences: effortPreferences
                        )
                        return SetModel(
                            userID: ForgeFitDemo.userID,
                            position: target.position,
                            setType: target.setType,
                            weightMode: weightMode,
                            // Block types never prefill reps: myo minis log
                            // what the lifter achieves live, and cluster reps
                            // mirror the logged segments. Plans ride the
                            // planned* fields as ghost targets instead.
                            reps: target.setType.isBlockType ? nil : target.targetRepsLow,
                            weight: weightMode == .external ? target.targetWeight : nil,
                            rpe: effort.rpe,
                            rir: effort.rir,
                            durationSeconds: target.targetDurationSeconds,
                            addedWeight: weightMode == .bodyweightAdded ? target.targetWeight : nil,
                            assistanceWeight: weightMode == .bodyweightAssisted ? target.targetWeight : nil,
                            sourceRoutineSetID: target.id,
                            plannedMiniSetCount: target.setType == .myoRep ? target.plannedMiniSetCount : nil,
                            plannedMiniRepsJSON: target.setType == .cluster ? target.plannedMiniRepsJSON : nil
                        )
                    }
                let workoutExercise = WorkoutExerciseModel(
                    userID: ForgeFitDemo.userID,
                    exerciseID: routineExercise.exerciseID,
                    position: routineExercise.position,
                    supersetGroup: routineExercise.supersetGroup,
                    notes: routineNote ?? setupNote.flatMap { ExerciseNotePolicy.authoredText($0.note) },
                    notePinned: routineNote == nil && setupNote != nil,
                    intervalPlanJSON: routineExercise.intervalPlanJSON,
                    yogaFlowJSON: routineExercise.yogaFlowJSON,
                    sourceRoutineExerciseID: routineExercise.id,
                    sets: pendingSets
                )
                if let exercise, exercise.isCardio {
                    let target = routineExercise.sets.sorted { $0.position < $1.position }.first
                    let kind = CardioKind.infer(name: exercise.name, equipment: exercise.equipment)
                    // Routine targets start as live goals, never pre-filled
                    // logged results: planned distance has not been covered,
                    // and planned duration is not elapsed time. An explicit
                    // goal already stored in the plan wins.
                    var plan = IntervalPlan.decode(from: workoutExercise.intervalPlanJSON)
                        ?? IntervalPlan(steps: [])
                    if plan.goal == nil {
                        if let meters = target?.targetDistanceMeters, meters > 0 {
                            plan.goal = .init(kind: .distance, value: meters)
                        } else if let seconds = target?.targetDurationSeconds, seconds > 0 {
                            plan.goal = .init(kind: .duration, value: Double(seconds))
                        }
                    }
                    workoutExercise.intervalPlanJSON = plan.isMeaningful ? plan.encodedJSON() : nil
                    cardioSessions.append(CardioSessionModel(
                        userID: ForgeFitDemo.userID,
                        workoutExerciseID: workoutExercise.id,
                        modality: kind.rawValue,
                        startedAt: workout.startedAt,
                        sourceDevice: "iphone-cardio-\(kind.rawValue)"
                    ))
                }
                return workoutExercise
            }
        workout.cardioSessions = cardioSessions
        for (index, item) in OrderedWorkoutItem.ordered(in: workout).enumerated() {
            item.position = index
        }
        persistenceContext.insert(workout)
        // Progression: advance pending targets from each exercise's last
        // session and record the explained suggestions. Single choke point —
        // Home, coach's version, quick starts, and watch starts all land here.
        // A weekly review's accepted progression holds (Coach's Corner) ride
        // along here too, so a held exercise starts held no matter which
        // entry point started the workout — and Corner's progression preview
        // reads the identical overrides, so preview always matches start.
        let holds = CoachWeeklyReview.activeProgressionHolds(in: persistenceContext)
        ProgressionPlanner.apply(
            to: workout, routine: routine, exercises: exercises, in: persistenceContext,
            heldExerciseIDs: holds.ids, holdReasons: holds.reasons
        )
        prepare(workout, persistenceContext)
        return commit(
            workout,
            from: persistenceContext,
            into: context,
            saveCenter: saveCenter ?? .shared,
            save: save,
            onCommit: onCommit
        )
    }

    private static func makeBlockSession(
        for block: WorkoutBlockModel,
        workoutStartedAt: Date
    ) -> CardioSessionModel {
        let yogaPlan = block.kind == .yoga ? YogaFlowPlan.decode(from: block.planSnapshotJSON) : nil
        return CardioSessionModel(
            userID: block.userID,
            workoutBlockID: block.id,
            modality: block.kind == .yoga ? CardioSessionModel.yogaModality : CardioSessionModel.conditioningModality,
            startedAt: workoutStartedAt,
            sourceDevice: block.kind == .yoga ? "iphone-yoga" : "iphone-conditioning",
            durationSeconds: yogaPlan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil },
            yogaStyleRaw: yogaPlan?.styleRaw
        )
    }

    /// Quick-start a guided yoga class from a flow (built-in or user-saved).
    @discardableResult
    static func startYoga(
        flow: YogaFlowPlan,
        named title: String,
        exercises: [ExerciseLibraryModel],
        in context: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (WorkoutModel) -> Void
    ) -> WorkoutModel? {
        let persistenceContext = ModelContext(context.container)
        persistenceContext.autosaveEnabled = false
        let startedAt = Date()
        let block = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .yoga,
            position: 0,
            planSnapshotJSON: flow.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: startedAt,
            sourceDevice: "iphone-yoga",
            durationSeconds: flow.totalSeconds > 0 ? flow.totalSeconds : nil,
            yogaStyleRaw: flow.styleRaw
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: startedAt,
            sourceDevice: "iphone-yoga",
            cardioSessions: [session],
            blocks: [block]
        )
        persistenceContext.insert(workout)
        return commit(
            workout,
            from: persistenceContext,
            into: context,
            saveCenter: saveCenter ?? .shared,
            save: save,
            onCommit: onCommit
        )
    }

    @discardableResult
    static func startCardio(
        _ modality: CardioModality,
        exercises: [ExerciseLibraryModel],
        in context: ModelContext,
        saveCenter: PersistentChangeSaveCenter? = nil,
        save: @escaping SaveOperation = { try $0.save() },
        onCommit: @escaping @MainActor (WorkoutModel) -> Void
    ) -> WorkoutModel? {
        let persistenceContext = ModelContext(context.container)
        persistenceContext.autosaveEnabled = false
        let startedAt = Date()
        let exercise = exercises.first { $0.id == modality.exerciseID }
        let workoutExercise = exercise.map {
            WorkoutExerciseModel(userID: ForgeFitDemo.userID, exerciseID: $0.id, position: 0)
        }
        let cardioSession = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise?.id,
            modality: modality.rawValue,
            startedAt: startedAt,
            sourceDevice: "iphone"
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: modality.title,
            startedAt: startedAt,
            sourceDevice: "iphone-cardio-\(modality.rawValue)",
            exercises: workoutExercise.map { [$0] } ?? [],
            cardioSessions: [cardioSession]
        )
        persistenceContext.insert(workout)
        return commit(
            workout,
            from: persistenceContext,
            into: context,
            saveCenter: saveCenter ?? .shared,
            save: save,
            onCommit: onCommit
        )
    }
}
