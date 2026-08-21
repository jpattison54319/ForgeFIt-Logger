import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

#if canImport(ActivityKit)
@MainActor
struct WorkoutActivityControllerTests {
    @Test func conditioningActivityShowsRoundTargetAndFreshHeartRate() throws {
        let (container, context) = try TestStore.make()
        defer {
            LiveMetricsHub.shared.clearLiveMetrics()
            _ = container
        }

        let userID = UUID()
        let start = Date.now.addingTimeInterval(-90)
        let movements = [
            ConditioningMovement(exerciseID: UUID(), targetValue: 21),
            ConditioningMovement(exerciseID: UUID(), targetValue: 21)
        ]
        let section = ConditioningSection(
            name: "21–15–9 Ladder",
            format: .ladder,
            scoreKind: .elapsedTime,
            repScheme: [21, 15, 9],
            movements: movements
        )
        let plan = ConditioningPlan(sections: [section])
        let progress = ConditioningProgress(
            sectionIndex: 0,
            round: 1,
            startedAt: start,
            sectionStartedAt: start,
            status: .active
        )
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            planSnapshotJSON: plan.encodedJSON(),
            progressJSON: progress.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: start,
            liveStartedAt: start
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Conditioning",
            startedAt: start,
            cardioSessions: [session],
            blocks: [block]
        )
        context.insert(workout)
        LiveMetricsHub.shared.updateFromWatch(WatchLiveMetrics(heartRate: 147, asOf: .now))

        let state = WorkoutActivityController.shared.contentState(for: workout, exercises: [])
        #expect(state.mode == .conditioning)
        #expect(state.heartRate == 147)
        #expect(state.cardioMetric == "Round 1 of 3")
        #expect(state.cardioDetail == "21 / 21 reps · 0/3 rounds")
    }

    @Test func completedConditioningActivityDoesNotShowPhantomRoundOrTarget() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        let userID = UUID()
        let movement = ConditioningMovement(exerciseID: UUID(), targetValue: 21)
        let section = ConditioningSection(
            name: "21–15–9 Ladder",
            format: .ladder,
            scoreKind: .elapsedTime,
            repScheme: [21, 15, 9],
            ladderStep: 3,
            movements: [movement]
        )
        let plan = ConditioningPlan(sections: [section])
        let progress = ConditioningProgress(
            sectionIndex: 0,
            round: 4,
            startedAt: .now.addingTimeInterval(-90),
            status: .completed
        )
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            planSnapshotJSON: plan.encodedJSON(),
            progressJSON: progress.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: .now.addingTimeInterval(-90),
            liveStartedAt: .now.addingTimeInterval(-90)
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Conditioning",
            cardioSessions: [session],
            blocks: [block]
        )
        context.insert(workout)

        let state = WorkoutActivityController.shared.contentState(for: workout, exercises: [])

        #expect(state.cardioMetric == "Round 3 of 3")
        #expect(state.cardioDetail == "9 reps · 3/3 rounds")
    }
}
#endif
