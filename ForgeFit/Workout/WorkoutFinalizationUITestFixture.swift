#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum WorkoutFinalizationUITestFixture {
    static func seed(in context: ModelContext) throws -> WorkoutModel {
        let title = "Finalizing Strength"
        var descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == title }
        )
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let end = Date.now.addingTimeInterval(-20)
        let exercise = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Finalizing Bench Press",
            movementPattern: "push",
            primaryMuscles: ["chest"],
            secondaryMuscles: ["triceps", "shoulders"],
            equipment: "barbell"
        )
        let completedSet = SetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            setType: .working,
            reps: 8,
            weight: 100,
            rpe: 8,
            completedAt: end.addingTimeInterval(-30)
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            position: 0,
            sets: [completedSet]
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: end.addingTimeInterval(-35 * 60),
            endedAt: end,
            sourceDevice: "iphone",
            exercises: [workoutExercise]
        )
        context.insert(exercise)
        context.insert(workout)
        try context.save()
        return workout
    }
}
#endif
