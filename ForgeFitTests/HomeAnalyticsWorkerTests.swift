import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct HomeAnalyticsWorkerTests {
    @Test
    func scoreWorkerUsesANonMainSwiftDataExecutor() async throws {
        let container = try TestStore.makeContainer()
        let worker = HomeAnalyticsWorker(modelContainer: container)

        let isOnMainThread = await worker.isExecutingOnMainThreadForTesting()
        #expect(!isOnMainThread)

        let result = try await worker.calculateCurrent(HomeAnalyticsInput(
            healthMetrics: [],
            supplementalSignals: [],
            activityMetrics: [],
            todayCheckinTags: [],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        #expect(result.recovery.displayScore == nil)
        #expect(result.strain.score == nil)
    }

    @Test
    func bodyweightRepairFetchesOnlyEligibleMissingSets() async throws {
        let (container, context) = try TestStore.make()
        let userID = ForgeFitDemo.userID
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let assistedID = UUID()
        let externalID = UUID()

        let assisted = SetModel(
            id: assistedID,
            userID: userID,
            position: 0,
            weightMode: .bodyweightAssisted,
            reps: 10,
            assistanceWeight: 20,
            completedAt: completedAt
        )
        let external = SetModel(
            id: externalID,
            userID: userID,
            position: 1,
            weightMode: .external,
            reps: 8,
            weight: 100,
            completedAt: completedAt
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            sets: [assisted, external]
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: completedAt.addingTimeInterval(-600),
            endedAt: completedAt,
            exercises: [workoutExercise]
        )
        context.insert(workout)
        try context.save()

        let worker = HomeAnalyticsWorker(modelContainer: container)
        try await worker.fillMissingBodyweight(from: [
            BodyweightSample(date: completedAt, value: 82)
        ])

        let verificationContext = ModelContext(container)
        let sets = try verificationContext.fetch(FetchDescriptor<SetModel>())
        let repaired = sets.first { $0.id == assistedID }
        let untouched = sets.first { $0.id == externalID }
        #expect(repaired?.bodyweightKg == 82)
        #expect(repaired?.totalVolume == 620)
        #expect(untouched?.bodyweightKg == nil)
        #expect(untouched?.totalVolume == 800)
    }
}
