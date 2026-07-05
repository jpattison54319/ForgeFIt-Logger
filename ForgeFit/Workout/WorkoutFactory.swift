import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// Cardio modalities offered as quick-starts.
enum CardioModality: String, CaseIterable, Identifiable {
    case run, cycle, row, walk

    var id: String { rawValue }
    var title: String {
        switch self {
        case .run: "Run"
        case .cycle: "Ride"
        case .row: "Row"
        case .walk: "Zone 2 Walk"
        }
    }
    var systemImage: String {
        switch self {
        case .run: "figure.run"
        case .cycle: "figure.outdoor.cycle"
        case .row: "figure.rower"
        case .walk: "figure.walk"
        }
    }
    var exerciseID: UUID? {
        switch self {
        case .run: GlobalExerciseLibrary.treadmillRunID
        case .cycle: GlobalExerciseLibrary.indoorCycleID
        case .row: GlobalExerciseLibrary.rowErgID
        case .walk: GlobalExerciseLibrary.treadmillRunID
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
        let exerciseByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        let resolvedSetupNotes = setupNotes + ((try? context.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? [])
        var cardioSessions: [CardioSessionModel] = []
        workout.exercises = routine.exercises
            .sorted { $0.position < $1.position }
            .map { routineExercise in
                let exercise = exerciseByID[routineExercise.exerciseID]
                let setupNote = resolvedSetupNotes.first {
                    $0.exerciseID == routineExercise.exerciseID && $0.userID == ForgeFitDemo.userID
                }
                let pendingSets: [SetModel] = exercise?.isCardio == true ? [] : routineExercise.sets
                    .sorted { $0.position < $1.position }
                    .map { target in
                        SetModel(
                            userID: ForgeFitDemo.userID,
                            position: target.position,
                            setType: target.setType,
                            reps: target.targetRepsLow,
                            weight: target.targetWeight,
                            rpe: target.targetRPE,
                            rir: target.targetRIR,
                            durationSeconds: target.targetDurationSeconds,
                            sourceRoutineSetID: target.id
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
                    sourceRoutineExerciseID: routineExercise.id,
                    sets: pendingSets
                )
                if let exercise, exercise.isCardio {
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
