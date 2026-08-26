import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ImportedExerciseReviewServiceTests {
    private enum InjectedFailure: Error {
        case save
    }

    @Test func bulkApproveIsDurableInAFreshContext() throws {
        let (container, context) = try TestStore.make()
        let first = pendingExercise(named: "Lat Prayer")
        let second = pendingExercise(named: "Lean Back Abduction Machine")
        context.insert(first)
        context.insert(second)
        try context.save()
        let ids = [first.id, second.id]

        try ImportedExerciseReviewService.apply(.approve, to: ids, in: container)

        let verification = ModelContext(container)
        let approved = try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { ids.contains($0.id) }
        ))
        #expect(approved.count == 2)
        #expect(approved.allSatisfy { $0.userModified })
        #expect(approved.allSatisfy { !$0.needsReview })
        #expect(approved.allSatisfy { $0.deletedAt == nil })
        #expect(approved.allSatisfy { $0.classificationSource == .manual })
        #expect(approved.allSatisfy { $0.classificationConfidence == 1 })
    }

    @Test func discardRemovesLibraryEntryButPreservesImportedWorkoutHistory() throws {
        let (container, context) = try TestStore.make()
        let exercise = pendingExercise(named: "Lat Prayer")
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 12,
            weight: 25,
            completedAt: .now
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            sets: [set]
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Imported Pull",
            startedAt: .now.addingTimeInterval(-1_800),
            endedAt: .now,
            externalSource: WorkoutImportSource.hevy.rawValue,
            importBatchID: exercise.importBatchID,
            exercises: [workoutExercise]
        )
        context.insert(exercise)
        context.insert(workout)
        try context.save()
        let exerciseID = exercise.id
        let workoutID = workout.id

        try ImportedExerciseReviewService.apply(.discard, to: [exerciseID], in: container)

        let verification = ModelContext(container)
        let discarded = try #require(try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID }
        )).first)
        let persistedWorkout = try #require(try verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        #expect(discarded.deletedAt != nil)
        #expect(discarded.userModified)
        #expect(!discarded.needsReview)
        #expect(persistedWorkout.deletedAt == nil)
        #expect(persistedWorkout.exercises.count == 1)
        #expect(persistedWorkout.exercises.first?.exerciseID == exerciseID)
        #expect(persistedWorkout.exercises.first?.sets.count == 1)
    }

    @Test func failedBulkActionRollsBackEveryExercise() throws {
        let (container, context) = try TestStore.make()
        let first = pendingExercise(named: "First")
        let second = pendingExercise(named: "Second")
        context.insert(first)
        context.insert(second)
        try context.save()
        let ids = [first.id, second.id]

        #expect(throws: InjectedFailure.save) {
            try ImportedExerciseReviewService.apply(
                .discard,
                to: ids,
                in: container,
                save: { _ in throw InjectedFailure.save }
            )
        }

        let verification = ModelContext(container)
        let exercises = try verification.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { ids.contains($0.id) }
        ))
        #expect(exercises.count == 2)
        #expect(exercises.allSatisfy { $0.deletedAt == nil })
        #expect(exercises.allSatisfy { !$0.userModified })
        #expect(exercises.allSatisfy { $0.needsReview })
    }

    private func pendingExercise(named name: String) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: name,
            primaryMuscles: ["lats"],
            userModified: false,
            needsReview: true,
            classificationConfidence: 0.6,
            classificationSourceRaw: ClassificationSource.seedFuzzy.rawValue,
            importBatchID: UUID(),
            importedRawName: name
        )
    }
}
