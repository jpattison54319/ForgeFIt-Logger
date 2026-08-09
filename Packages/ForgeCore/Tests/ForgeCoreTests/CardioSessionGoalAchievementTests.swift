import Testing
@testable import ForgeCore

struct CardioSessionGoalAchievementTests {
    @Test func thresholdIsConsumedExactlyOnce() {
        var tracker = CardioSessionGoalAchievementTracker(
            goal: .init(kind: .distance, value: 5_000)
        )

        let missingReading = tracker.consume(current: nil)
        let belowTarget = tracker.consume(current: 4_999.9)
        let exactTarget = tracker.consume(current: 5_000)
        let repeatedAboveTarget = tracker.consume(current: 5_200)

        #expect(!missingReading)
        #expect(!belowTarget)
        #expect(exactTarget)
        #expect(!repeatedAboveTarget)
        #expect(tracker.hasReachedGoal)
    }

    @Test func invalidTargetsAndReadingsNeverComplete() {
        var emptyGoal = CardioSessionGoalAchievementTracker(
            goal: .init(kind: .duration, value: 0)
        )
        var validGoal = CardioSessionGoalAchievementTracker(
            goal: .init(kind: .calories, value: 300)
        )

        let invalidTarget = emptyGoal.consume(current: 10)
        let notANumber = validGoal.consume(current: .nan)
        let infinite = validGoal.consume(current: .infinity)

        #expect(!invalidTarget)
        #expect(!notANumber)
        #expect(!infinite)
    }

    @Test func distancePhraseUsesTheSelectedUnit() {
        let goal = IntervalPlan.SessionGoal(
            kind: .distance,
            value: DistanceUnit.mi.meters(fromDistance: 3.1)
        )

        #expect(
            CardioSessionGoalAnnouncement.phrase(for: goal, distanceUnit: .mi)
                == "You hit your distance goal of 3.1 miles."
        )
    }

    @Test func everyGoalKindHasNaturalSpokenWording() {
        #expect(
            CardioSessionGoalAnnouncement.phrase(
                for: .init(kind: .distance, value: 400),
                distanceUnit: .km,
                usesFixedMeters: true
            ) == "You hit your distance goal of 400 meters."
        )
        #expect(
            CardioSessionGoalAnnouncement.phrase(
                for: .init(kind: .duration, value: 1_800),
                distanceUnit: .km
            ) == "You hit your time goal of 30 minutes."
        )
        #expect(
            CardioSessionGoalAnnouncement.phrase(
                for: .init(kind: .calories, value: 1),
                distanceUnit: .km
            ) == "You hit your calorie goal of 1 calorie."
        )
        #expect(
            CardioSessionGoalAnnouncement.phrase(
                for: .init(kind: .elevation, value: 300),
                distanceUnit: .km
            ) == "You hit your climb goal of 300 meters."
        )
    }
}
