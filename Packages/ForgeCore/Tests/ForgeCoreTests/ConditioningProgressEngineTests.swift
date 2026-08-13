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

    @Test func completedRoundsCaptureActiveTimeSplits() throws {
        let plan = cindy
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start, action: .start),
            to: ConditioningProgress(),
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(30), action: .completeRound),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(40), action: .pause),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(60), action: .resume),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(100), action: .completeRound),
            to: progress,
            plan: plan
        )

        #expect(progress.roundCompletionElapsedSeconds == [30, 80])
        let result = try #require(ConditioningProgressEngine.result(
            for: progress,
            plan: plan,
            at: start.addingTimeInterval(120)
        ).sectionResults.first)
        #expect(result.roundCompletionElapsedSeconds == [30, 80])
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

    @Test func manualRoundCorrectionInvalidatesCapturedPacing() {
        let plan = cindy
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start, action: .start),
            to: ConditioningProgress(),
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(30), action: .completeRound),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(
                timestamp: start.addingTimeInterval(40),
                action: .setScore(rounds: 3, partialMovementID: nil, partialValue: 0, load: nil)
            ),
            to: progress,
            plan: plan
        )

        #expect(progress.fullRounds == 3)
        #expect(progress.roundCompletionElapsedSeconds == nil)
    }

    @Test func confirmedTimedScoreReplacesProvisionalResultWithoutInventingSplits() throws {
        let plan = cindy
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start, action: .start),
            to: ConditioningProgress(),
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(300), action: .completeRound),
            to: progress,
            plan: plan
        )
        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(timestamp: start.addingTimeInterval(1_200), action: .expire),
            to: progress,
            plan: plan
        )
        #expect(progress.sectionResults.first?.roundCompletionElapsedSeconds == [300])

        progress = ConditioningProgressEngine.apply(
            ConditioningProgressEvent(
                timestamp: start.addingTimeInterval(1_201),
                action: .setScore(rounds: 3, partialMovementID: nil, partialValue: 0, load: nil)
            ),
            to: progress,
            plan: plan
        )
        let result = try #require(ConditioningProgressEngine.result(for: progress, plan: plan).sectionResults.first)

        #expect(result.fullRounds == 3)
        #expect(result.totalReps == 90)
        #expect(result.roundCompletionElapsedSeconds == nil)
        #expect(result.completed)
    }

    @Test func performanceAnalysisMeasuresRoundPaceAndSlowdown() throws {
        let section = ConditioningSection(
            name: "Four rounds",
            format: .forTime,
            rounds: 4,
            movements: [ConditioningMovement(exerciseID: pullUpID, targetValue: 100)]
        )
        let result = ConditioningSectionResult(
            id: section.id,
            format: .forTime,
            scoreKind: .elapsedTime,
            elapsedSeconds: 220,
            fullRounds: 4,
            totalReps: 400,
            roundCompletionElapsedSeconds: [40, 85, 145, 220],
            completed: true
        )

        let analysis = ConditioningPerformanceAnalysis(section: section, result: result)
        #expect(analysis.roundSplits.map(\.durationSeconds) == [40, 45, 60, 75])
        #expect(analysis.averageRoundSeconds == 55)
        #expect(analysis.averageLoggedSplitSeconds == 55)
        #expect(analysis.fastestRoundSeconds == 40)
        #expect(analysis.slowestRoundSeconds == 75)
        #expect(abs(try #require(analysis.secondHalfPaceChangePercent) - 58.823_529) < 0.001)
        #expect(abs(try #require(analysis.repsPerMinute) - 109.090_909) < 0.001)
        #expect(analysis.completionPercent == 100)
        #expect(analysis.missedRounds == 0)
    }

    @Test func variableLadderDoesNotClaimRoundPacingIsComparable() {
        let section = ConditioningSection(
            name: "21-15-9",
            format: .ladder,
            scoreKind: .elapsedTime,
            repScheme: [21, 15, 9],
            movements: [ConditioningMovement(exerciseID: pullUpID, targetValue: 21)]
        )
        let result = ConditioningSectionResult(
            id: section.id,
            format: .ladder,
            scoreKind: .elapsedTime,
            elapsedSeconds: 180,
            fullRounds: 3,
            totalReps: 45,
            roundCompletionElapsedSeconds: [90, 150, 180],
            completed: true
        )

        let analysis = ConditioningPerformanceAnalysis(section: section, result: result)
        #expect(analysis.roundSplits.map(\.durationSeconds) == [90, 60, 30])
        #expect(analysis.averageRoundSeconds == nil)
        #expect(analysis.fastestRoundSeconds == nil)
        #expect(analysis.secondHalfPaceChangePercent == nil)
        #expect(analysis.repsPerMinute == 15)
        #expect(analysis.completionPercent == 100)
    }

    @Test func completedLegacyForTimeResultInfersPrescribedRounds() {
        let section = ConditioningSection(
            name: "Legacy rounds",
            format: .forTime,
            rounds: 3,
            movements: [ConditioningMovement(exerciseID: pullUpID, targetValue: 10)]
        )
        let result = ConditioningSectionResult(
            id: section.id,
            format: .forTime,
            scoreKind: .elapsedTime,
            elapsedSeconds: 180,
            totalReps: 30,
            completed: true
        )

        let analysis = ConditioningPerformanceAnalysis(section: section, result: result)
        #expect(analysis.completedRounds == 3)
        #expect(analysis.averageRoundSeconds == 60)
        #expect(analysis.completionPercent == 100)
    }
}
