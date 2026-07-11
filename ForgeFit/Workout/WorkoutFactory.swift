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
enum WorkoutFactory {

    @discardableResult
    static func startEmpty(in context: ModelContext) -> WorkoutModel {
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Workout",
            sourceDevice: "iphone"
        )
        context.insert(workout)
        try? context.save()
        return workout
    }

    @discardableResult
    static func start(
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        setupNotes: [UserExerciseNoteModel] = [],
        in context: ModelContext
    ) -> WorkoutModel {
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routine.id,
            title: routine.name,
            sourceDevice: "iphone"
        )
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resolvedSetupNotes = setupNotes + ((try? context.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? [])
        var cardioSessions: [CardioSessionModel] = []
        workout.exercises = routine.exercises
            .sorted { $0.position < $1.position }
            .map { routineExercise in
                let exercise = exerciseByID[routineExercise.exerciseID]
                let setupNote = resolvedSetupNotes.first {
                    $0.exerciseID == routineExercise.exerciseID && $0.userID == ForgeFitDemo.userID
                }
                // Cardio and yoga exercises log as sessions, not set rows.
                let isSessionBased = exercise?.isCardio == true || exercise?.isYoga == true
                let pendingSets: [SetModel] = isSessionBased ? [] : routineExercise.sets
                    .sorted { $0.position < $1.position }
                    .map { target in
                        SetModel(
                            userID: ForgeFitDemo.userID,
                            position: target.position,
                            setType: target.setType,
                            // Block types never prefill reps: myo minis log
                            // what the lifter achieves live, and cluster reps
                            // mirror the logged segments. Plans ride the
                            // planned* fields as ghost targets instead.
                            reps: target.setType.isBlockType ? nil : target.targetRepsLow,
                            weight: target.targetWeight,
                            rpe: target.targetRPE,
                            rir: target.targetRIR,
                            durationSeconds: target.targetDurationSeconds,
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
                    notes: routineExercise.notes ?? setupNote?.note,
                    notePinned: routineExercise.notes == nil && setupNote != nil,
                    intervalPlanJSON: routineExercise.intervalPlanJSON,
                    yogaFlowJSON: routineExercise.yogaFlowJSON,
                    sourceRoutineExerciseID: routineExercise.id,
                    sets: pendingSets
                )
                if let exercise, exercise.isYoga {
                    // Legacy pose rows still synthesize a runnable hold. The
                    // new Yoga Session row can stay empty until configured.
                    let plan = YogaFlowPlan.decode(from: routineExercise.yogaFlowJSON)
                        ?? (YogaPoseCatalog.isSessionExercise(exercise) ? nil : .singlePose(from: exercise))
                    if workoutExercise.yogaFlowJSON == nil {
                        workoutExercise.yogaFlowJSON = plan?.encodedJSON()
                    }
                    cardioSessions.append(CardioSessionModel(
                        userID: ForgeFitDemo.userID,
                        workoutExerciseID: workoutExercise.id,
                        modality: CardioSessionModel.yogaModality,
                        startedAt: workout.startedAt,
                        sourceDevice: "iphone-yoga",
                        durationSeconds: plan.flatMap { $0.totalSeconds > 0 ? $0.totalSeconds : nil },
                        yogaStyleRaw: plan?.styleRaw
                    ))
                } else if let exercise, exercise.isCardio {
                    let target = routineExercise.sets.sorted { $0.position < $1.position }.first
                    let kind = CardioKind.infer(name: exercise.name, equipment: exercise.equipment)
                    cardioSessions.append(CardioSessionModel(
                        userID: ForgeFitDemo.userID,
                        workoutExerciseID: workoutExercise.id,
                        modality: kind.rawValue,
                        startedAt: workout.startedAt,
                        sourceDevice: "iphone-cardio-\(kind.rawValue)",
                        durationSeconds: target?.targetDurationSeconds
                    ))
                }
                return workoutExercise
            }
        workout.cardioSessions = cardioSessions
        context.insert(workout)
        // Progression: advance pending targets from each exercise's last
        // session and record the explained suggestions. Single choke point —
        // Home, coach's version, quick starts, and watch starts all land here.
        // A weekly review's accepted progression holds (Coach's Corner) ride
        // along here too, so a held exercise starts held no matter which
        // entry point started the workout — and Corner's progression preview
        // reads the identical overrides, so preview always matches start.
        let holds = CoachWeeklyReview.activeProgressionHolds(in: context)
        ProgressionPlanner.apply(
            to: workout, routine: routine, exercises: exercises, in: context,
            heldExerciseIDs: holds.ids, holdReasons: holds.reasons
        )
        try? context.save()
        return workout
    }

    /// Quick-start a guided yoga class from a flow (built-in or user-saved).
    /// The workout exercise anchors on the Yoga Session row; poses live inside
    /// the flow, not as nested workout exercises.
    @discardableResult
    static func startYoga(
        flow: YogaFlowPlan,
        named title: String,
        exercises: [ExerciseLibraryModel],
        in context: ModelContext
    ) -> WorkoutModel {
        let startedAt = Date()
        let anchor = exercises.first { YogaPoseCatalog.isSessionExercise($0) && $0.deletedAt == nil }
            ?? YogaPoseCatalog.sessionExercise(in: context)
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: anchor.id,
            position: 0,
            yogaFlowJSON: flow.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
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
            notes: "Yoga session",
            exercises: [workoutExercise],
            cardioSessions: [session]
        )
        context.insert(workout)
        try? context.save()
        return workout
    }

    @discardableResult
    static func startCardio(_ modality: CardioModality, exercises: [ExerciseLibraryModel], in context: ModelContext) -> WorkoutModel {
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
            notes: "Cardio workout",
            exercises: workoutExercise.map { [$0] } ?? [],
            cardioSessions: [cardioSession]
        )
        context.insert(workout)
        try? context.save()
        return workout
    }
}
