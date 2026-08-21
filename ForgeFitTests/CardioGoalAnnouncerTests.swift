import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct CardioGoalAnnouncerTests {
    @Test func multipleLiveSourcesStillDeliverOnlyOnce() {
        var delivered: [String] = []
        let announcer = CardioGoalAnnouncer { delivered.append($0) }
        let sessionID = UUID()
        let startedAt = Date.now
        let goal = IntervalPlan.SessionGoal(kind: .distance, value: 5_000)

        announcer.activate(
            sessionID: sessionID,
            goal: goal,
            startedAt: startedAt,
            cardioKind: .run,
            distanceUnit: .km
        )
        announcer.evaluate(sessionID: sessionID, distanceMeters: 4_999)
        announcer.evaluateCurrent(sessionID: sessionID, current: 5_000)
        announcer.evaluate(sessionID: sessionID, distanceMeters: 5_100)
        // A stable view rebuilding around the same live session must not reset
        // the one-shot threshold state.
        announcer.activate(
            sessionID: sessionID,
            goal: goal,
            startedAt: startedAt,
            cardioKind: .run,
            distanceUnit: .km
        )
        announcer.evaluateCurrent(sessionID: sessionID, current: 5_200)

        #expect(delivered == ["You hit your distance goal of 5 kilometers."])
        announcer.cancelAll()
    }

    @Test func watchCaloriesAreScopedToTheCardioSegment() {
        var delivered: [String] = []
        let announcer = CardioGoalAnnouncer { delivered.append($0) }
        let sessionID = UUID()

        announcer.activate(
            sessionID: sessionID,
            goal: .init(kind: .calories, value: 300),
            startedAt: .now,
            cardioKind: .cycle,
            distanceUnit: .mi,
            liveEnergyBaseline: 250
        )

        #expect(announcer.segmentActiveEnergy(sessionID: sessionID, cumulativeTotal: 400) == 150)
        announcer.evaluate(sessionID: sessionID, liveActiveEnergyTotalKcal: 549)
        #expect(delivered.isEmpty)
        announcer.evaluate(sessionID: sessionID, liveActiveEnergyTotalKcal: 550)
        #expect(delivered == ["You hit your calorie goal of 300 calories."])
        announcer.cancelAll()
    }

    @Test func finalWindowedMeasurementCanCompleteAWaitingGoal() {
        var delivered: [String] = []
        let announcer = CardioGoalAnnouncer { delivered.append($0) }
        let sessionID = UUID()

        announcer.activate(
            sessionID: sessionID,
            goal: .init(kind: .elevation, value: 300),
            startedAt: .now,
            cardioKind: .trailRun,
            distanceUnit: .km
        )
        announcer.finish(
            sessionID: sessionID,
            distanceMeters: 10_000,
            durationSeconds: 3_600,
            activeEnergyKcal: 700,
            elevationGainMeters: 305
        )

        #expect(delivered == ["You hit your climb goal of 300 meters."])
        #expect(!announcer.isTracking(sessionID: sessionID))
    }

    @Test func durationGoalUsesTheSegmentClockWithoutAVisibleCard() {
        var delivered: [String] = []
        let announcer = CardioGoalAnnouncer { delivered.append($0) }
        let sessionID = UUID()

        announcer.activate(
            sessionID: sessionID,
            goal: .init(kind: .duration, value: 1_800),
            startedAt: .now,
            cardioKind: .elliptical,
            distanceUnit: .km
        )
        announcer.evaluate(sessionID: sessionID, elapsedSeconds: 1_799)
        #expect(delivered.isEmpty)
        announcer.evaluate(sessionID: sessionID, elapsedSeconds: 1_800)
        #expect(delivered == ["You hit your time goal of 30 minutes."])
        announcer.cancelAll()
    }

    @Test func oddSecondDurationUsesOneExactDisplayAndAnnouncementThreshold() {
        let goal = IntervalPlan.SessionGoal(kind: .duration, value: 535)
        let before = CardioGoalProgressState(goal: goal, current: 489)

        #expect(CardioGoalFormatting.pair(goal: goal, current: 489, kind: .run) == "8:09 of 8:55")
        #expect(before.roundedPercent == 91)
        #expect(!before.reached)

        var delivered: [String] = []
        let announcer = CardioGoalAnnouncer { delivered.append($0) }
        let sessionID = UUID()
        announcer.activate(
            sessionID: sessionID,
            goal: goal,
            startedAt: .now,
            cardioKind: .run,
            distanceUnit: .km
        )
        announcer.evaluate(sessionID: sessionID, elapsedSeconds: 534)
        #expect(delivered.isEmpty)
        announcer.evaluate(sessionID: sessionID, elapsedSeconds: 535)

        let reached = CardioGoalProgressState(goal: goal, current: 535)
        #expect(CardioGoalFormatting.pair(goal: goal, current: 535, kind: .run) == "8:55 of 8:55")
        #expect(reached.roundedPercent == 100)
        #expect(reached.reached)
        #expect(delivered == ["You hit your time goal of 8 minutes 55 seconds."])
        announcer.cancelAll()
    }
}
