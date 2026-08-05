import Foundation
import Testing
@testable import ForgeCore

struct ConditioningProgressEngineTests {
    private let pullUpID = UUID()
    private let pushUpID = UUID()
    private let squatID = UUID()

    private var cindy: ConditioningPlan {
        ConditioningPlan(sections: [
            ConditioningSection(
                name: "Cindy",
                format: .amrap,
                durationSeconds: 1_200,
                movements: [
                    ConditioningMovement(exerciseID: pullUpID, targetValue: 5, weightMode: .bodyweight),
                    ConditioningMovement(exerciseID: pushUpID, targetValue: 10, weightMode: .bodyweight),
                    ConditioningMovement(exerciseID: squatID, targetValue: 15, weightMode: .bodyweight)
                ]
            )
        ])
    }

    @Test func completeRoundCommitsEveryMovementOnce() throws {
        let plan = cindy
        let started = Date(timeIntervalSince1970: 1_000)
        var progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: started, action: .start),
            to: ConditioningProgress(),
            plan: plan
        )
        let first = try #require(plan.sections.first?.movements.first)
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: started.addingTimeInterval(10), action: .toggleMovement(first.id)),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: started.addingTimeInterval(20), action: .completeRound),
            to: progress,
            plan: plan
        )

        #expect(progress.fullRounds == 1)
        #expect(progress.movementTotals[first.id] == 5)
        #expect(progress.movementTotals.values.reduce(0, +) == 30)
    }

    @Test func duplicateCrossDeviceEventIsIdempotent() {
        let plan = cindy
        var progress = ConditioningProgress(status: .active)
        let event = ConditioningProgressEvent(action: .completeRound)
        progress = ConditioningProgressEngine.apply(event, to: progress, plan: plan)
        progress = ConditioningProgressEngine.apply(event, to: progress, plan: plan)
        #expect(progress.fullRounds == 1)
        #expect(progress.movementTotals.values.reduce(0, +) == 30)
    }

    @Test func pauseExcludesPausedTime() {
        let plan = cindy
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start, action: .start),
            to: ConditioningProgress(),
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(30), action: .pause),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(50), action: .resume),
            to: progress,
            plan: plan
        )
        #expect(ConditioningProgressEngine.elapsedSeconds(for: progress, at: start.addingTimeInterval(80)) == 60)
    }

    @Test func repSchemeCompletesForTimeWorkout() throws {
        let movement = ConditioningMovement(exerciseID: pullUpID, targetValue: 21)
        let plan = ConditioningPlan(sections: [
            ConditioningSection(name: "21-15-9", format: .forTime, repScheme: [21, 15, 9], movements: [movement])
        ])
        var progress = ConditioningProgress(status: .active)
        for _ in 0..<3 {
            progress = ConditioningProgressEngine.apply(ConditioningProgressEvent(action: .completeRound), to: progress, plan: plan)
        }
        #expect(progress.status == .completed)
        #expect(progress.movementTotals[movement.id] == 45)
    }

    @Test func untimedFixedWorkMustReachItsTargetBeforeFinishing() {
        let movement = ConditioningMovement(exerciseID: pullUpID, targetValue: 10)
        let section = ConditioningSection(
            name: "Ten rounds",
            format: .forTime,
            rounds: 10,
            movements: [movement]
        )
        let plan = ConditioningPlan(sections: [section])

        #expect(ConditioningProgressEngine.requiredRoundsRemaining(
            for: ConditioningProgress(round: 5, status: .active),
            plan: plan
        ) == 6)
        #expect(ConditioningProgressEngine.requiredRoundsRemaining(
            for: ConditioningProgress(round: 11, status: .completed),
            plan: plan
        ) == 0)

        var cappedSection = section
        cappedSection.timeCapSeconds = 600
        #expect(ConditioningProgressEngine.requiredRoundsRemaining(
            for: ConditioningProgress(round: 5, status: .active),
            plan: ConditioningPlan(sections: [cappedSection])
        ) == 0)
    }

    @Test func legacyPartialEventIsIgnored() {
        let plan = cindy
        let movement = plan.sections[0].movements[0]
        var progress = ConditioningProgress(status: .active)
        progress = ConditioningProgressEngine.apply(ConditioningProgressEvent(action: .completeRound), to: progress, plan: plan)
        progress = ConditioningProgressEngine.apply(ConditioningProgressEvent(action: .setPartial(movement.id, 3)), to: progress, plan: plan)
        progress = ConditioningProgressEngine.apply(ConditioningProgressEvent(action: .expire), to: progress, plan: plan)
        let result = ConditioningProgressEngine.result(for: progress, plan: plan)
        #expect(result.sectionResults[0].fullRounds == 1)
        #expect(result.sectionResults[0].partialValue == nil)
        #expect(result.sectionResults[0].totalReps == 30)
    }

    @Test func manualScoreCorrectionRebuildsOnlyFullRounds() {
        let plan = cindy
        let partial = plan.sections[0].movements[1]
        var progress = ConditioningProgress(status: .active)
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(action: .setScore(rounds: 7, partialMovementID: partial.id, partialValue: 4, load: nil)),
            to: progress,
            plan: plan
        )
        let result = ConditioningProgressEngine.result(for: progress, plan: plan)
        #expect(progress.fullRounds == 7)
        #expect(progress.movementTotals.values.reduce(0, +) == 210)
        #expect(result.sectionResults[0].partialMovementID == nil)
        #expect(result.sectionResults[0].partialValue == nil)
        #expect(result.sectionResults[0].totalReps == 210)
    }
}
