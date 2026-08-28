import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@Suite("Routine detail analytics worker")
struct RoutineDetailAnalyticsWorkerTests {
    @MainActor
    @Test("Equal-volume historical edits refresh e1RM and reps from a fresh context")
    func equalVolumeEditRefreshesEveryProjection() async throws {
        let (container, context) = try TestStore.make()
        let routineID = UUID()
        let exerciseID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 5,
            weight: 100,
            completedAt: startedAt.addingTimeInterval(30)
        )
        set.recomputeDerivedMetrics()
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            updatedAt: startedAt.addingTimeInterval(60),
            exercises: [WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: exerciseID,
                sets: [set]
            )]
        )
        workout.recomputeTotalVolume()
        context.insert(workout)
        try context.save()

        let worker = RoutineDetailAnalyticsWorker(modelContainer: container)
        let first = try await worker.calculate(routineID: routineID)
        let firstFingerprint = AnalyticsFingerprint.of([workout])

        // 100 x 5 and 125 x 4 both total 500 kg, but their rep/e1RM
        // projections differ. Normal history mutation boundaries stamp the
        // parent clock even when the aggregate volume is unchanged.
        set.weight = 125
        set.reps = 4
        set.updatedAt = startedAt.addingTimeInterval(120)
        set.recomputeDerivedMetrics()
        workout.updatedAt = startedAt.addingTimeInterval(120)
        workout.recomputeTotalVolume()
        try context.save()

        let second = try await worker.calculate(routineID: routineID)
        #expect(workout.totalVolume == 500)
        #expect(first.series(for: .volume).map(\.value) == [500])
        #expect(second.series(for: .volume).map(\.value) == [500])
        #expect(first.series(for: .reps).map(\.value) == [5])
        #expect(second.series(for: .reps).map(\.value) == [4])
        #expect(first.series(for: .duration).map(\.value) == [60])
        #expect(second.series(for: .duration).map(\.value) == [60])
        #expect(first.baselines[exerciseID] != second.baselines[exerciseID])
        #expect(AnalyticsFingerprint.of([workout]) != firstFingerprint)
    }
}
