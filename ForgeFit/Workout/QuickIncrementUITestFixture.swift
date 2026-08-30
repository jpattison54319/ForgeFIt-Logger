#if DEBUG
import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// Lightweight completed history for live-prefill regressions. The starter
/// routine has a different identity, and the second movement exists only in
/// history until the user replaces the live exercise.
@MainActor
enum QuickIncrementUITestFixture {
    static let livePrefillLaunchArgument = "--seed-live-prefill-regression"
    static let replacementExerciseName = "Dumbbell Bench Press"
    private static let liveRoutineID = UUID(uuidString: "00000000-0000-7000-8000-000000000941")!
    private static let liveRoutineExerciseID = UUID(uuidString: "00000000-0000-7000-8000-000000000942")!
    private static let liveRoutineSetID = UUID(uuidString: "00000000-0000-7000-8000-000000000943")!

    static func seed(in modelContext: ModelContext) throws {
        let title = "Quick Increment History Fixture"
        var descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == title }
        )
        descriptor.fetchLimit = 1
        guard try modelContext.fetch(descriptor).isEmpty else { return }

        let completedAt = Date().addingTimeInterval(-3_600)
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            setType: .working,
            reps: 10,
            weight: 97.5,
            completedAt: completedAt
        )
        let originalExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            sets: [set]
        )
        let replacementName = replacementExerciseName
        var replacementDescriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.name == replacementName && $0.deletedAt == nil }
        )
        replacementDescriptor.fetchLimit = 1
        let replacementExercise = try modelContext.fetch(replacementDescriptor).first.map { library in
            WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: library.id,
                position: 1,
                sets: [SetModel(
                    userID: ForgeFitDemo.userID,
                    position: 0,
                    setType: .working,
                    reps: 8,
                    weight: 42.5,
                    completedAt: completedAt
                )]
            )
        }
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: completedAt.addingTimeInterval(-1_800),
            endedAt: completedAt,
            exercises: [originalExercise] + [replacementExercise].compactMap { $0 }
        )
        workout.recomputeTotalVolume()
        modelContext.insert(workout)
        try modelContext.save()
    }

    /// Creates the exact reported state without relying on launch-time
    /// auto-start timing: a newly authored routine has no matching routine
    /// history, while both its initial exercise and a possible replacement do.
    static func seedLivePrefillWorkout(in modelContext: ModelContext) throws -> WorkoutModel {
        try seed(in: modelContext)

        let activeTitle = "Live Prefill Regression Fixture"
        var activeDescriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == activeTitle && $0.endedAt == nil }
        )
        activeDescriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(activeDescriptor).first { return existing }

        let routineSet = RoutineSetModel(
            id: liveRoutineSetID,
            userID: ForgeFitDemo.userID,
            position: 0,
            setType: .working,
            targetRepsLow: 8,
            targetRepsHigh: 8,
            targetWeight: 70
        )
        let routineExercise = RoutineExerciseModel(
            id: liveRoutineExerciseID,
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            sets: [routineSet]
        )
        var routineDescriptor = FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == liveRoutineID && $0.deletedAt == nil }
        )
        routineDescriptor.fetchLimit = 1
        if try modelContext.fetch(routineDescriptor).isEmpty {
            modelContext.insert(RoutineModel(
                id: liveRoutineID,
                userID: ForgeFitDemo.userID,
                name: "New Prefill Routine",
                position: 1,
                exercises: [routineExercise]
            ))
        }

        let liveSet = SetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            setType: .working,
            reps: 8,
            weight: 70,
            sourceRoutineSetID: liveRoutineSetID
        )
        let liveExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            sourceRoutineExerciseID: liveRoutineExerciseID,
            sets: [liveSet]
        )
        let active = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: liveRoutineID,
            title: activeTitle,
            startedAt: Date(),
            exercises: [liveExercise]
        )
        modelContext.insert(active)
        try modelContext.save()
        return active
    }
}
#endif
