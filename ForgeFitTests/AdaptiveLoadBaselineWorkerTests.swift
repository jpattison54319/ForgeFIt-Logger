import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@Suite("Routine editor adaptive-load worker")
struct AdaptiveLoadBaselineWorkerTests {
    @MainActor
    @Test("A newly completed assessment refreshes the detached baseline")
    func refreshesAfterNewCompletion() async throws {
        let (container, context) = try TestStore.make()
        let exerciseID = UUID()

        func insertEstimate(weight: Double, reps: Int, at date: Date) throws {
            let set = SetModel(
                userID: ForgeFitDemo.userID,
                reps: reps,
                weight: weight,
                completedAt: date
            )
            let workout = WorkoutModel(
                userID: ForgeFitDemo.userID,
                startedAt: date,
                endedAt: date.addingTimeInterval(60),
                exercises: [WorkoutExerciseModel(
                    userID: ForgeFitDemo.userID,
                    exerciseID: exerciseID,
                    sets: [set]
                )]
            )
            context.insert(workout)
            try context.save()
        }

        try insertEstimate(weight: 100, reps: 5, at: Date(timeIntervalSince1970: 1_000))
        let worker = AdaptiveLoadBaselineWorker(modelContainer: container)
        let first = try await worker.calculate()
        #expect(first[exerciseID] == 100 * (1 + 5.0 / 30.0))

        try insertEstimate(weight: 120, reps: 3, at: Date(timeIntervalSince1970: 2_000))
        let refreshed = try await worker.calculate()
        #expect(refreshed[exerciseID] == 120 * (1 + 3.0 / 30.0))
        #expect(await !worker.isExecutingOnMainThreadForTesting())
    }
}
