#if DEBUG
import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One lightweight completed set for the quick-increment UI regression. The
/// starter routine still carries 70 kg, while this previous session makes the
/// next live row visibly ghost 97.5 kg.
@MainActor
enum QuickIncrementUITestFixture {
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
