#if DEBUG
import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// Recreates the regular-row → Myo-rep failure: the routine carries a hidden
/// 50 lb target while Working history visibly ghosts 72.5 kg.
@MainActor
enum BlockPrefillUITestFixture {
    static func seed(in modelContext: ModelContext) throws {
        let targetID = ForgeFitDemo.starterRoutineSetID
        var targetDescriptor = FetchDescriptor<RoutineSetModel>(
            predicate: #Predicate { $0.id == targetID }
        )
        targetDescriptor.fetchLimit = 1
        if let target = try modelContext.fetch(targetDescriptor).first {
            target.targetWeight = 50 / 2.2046226218
        }

        let title = "Block Prefill History Fixture"
        var workoutDescriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == title }
        )
        workoutDescriptor.fetchLimit = 1
        guard try modelContext.fetch(workoutDescriptor).isEmpty else {
            try modelContext.save()
            return
        }

        let completedAt = Date().addingTimeInterval(-3_600)
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            setType: .working,
            reps: 10,
            weight: 72.5,
            completedAt: completedAt
        )
        let exercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            position: 0,
            sets: [set]
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: completedAt.addingTimeInterval(-1_800),
            endedAt: completedAt,
            exercises: [exercise]
        )
        workout.recomputeTotalVolume()
        modelContext.insert(workout)
        try modelContext.save()
    }
}
#endif
