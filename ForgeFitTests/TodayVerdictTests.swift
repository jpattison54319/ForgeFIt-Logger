import Foundation
import Testing
@testable import ForgeFit

struct TodayVerdictTests {
    @Test(arguments: [
        (0.39, RecoveryEngine.Action.reduceVolume),
        (0.50, .reduceVolume),
        (0.64, .reduceVolume),
        (0.65, .trainAsPlanned),
        (0.84, .trainAsPlanned),
        (0.85, .trainAsPlanned),
    ])
    func fixedBandsHaveOneAction(score: Double, expected: RecoveryEngine.Action) {
        #expect(TodayVerdict.make(score: score, checkinTags: []).action == expected)
    }

    @Test func ordinaryCheckinsAddContextWithoutChangingScoreDrivenAction() {
        let baseline = TodayVerdict.make(score: 0.75, checkinTags: [])
        let checkedIn = TodayVerdict.make(score: 0.75, checkinTags: ["sore", "stressed"])

        #expect(baseline.action == .trainAsPlanned)
        #expect(checkedIn.action == baseline.action)
        #expect(checkedIn.recommendation.contains("sore"))
        #expect(checkedIn.isCheckinOverride == false)
    }

    @Test func sickCheckinOverridesActionButNotTheNumericScore() {
        let baseline = TodayVerdict.make(score: 0.86, checkinTags: [])
        let checkedIn = TodayVerdict.make(score: 0.86, checkinTags: ["sick"])

        #expect(baseline.action == .trainAsPlanned)
        #expect(checkedIn.action == .deloadRecover)
        #expect(checkedIn.isCheckinOverride)
    }

    @Test func missingScoreProducesNoSyntheticFallback() {
        let verdict = TodayVerdict.make(score: nil, checkinTags: [])

        #expect(verdict.action == .insufficientData)
        #expect(verdict.recommendation.contains("Not enough comparable data"))
    }

    @Test func checkinDoesNotChangeRecoveryEngineDisplayScore() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let health = (0..<40).map { day in
            RecoveryEngine.DailyHealthMetric(
                date: now.addingTimeInterval(-Double(day) * 86_400),
                hrvSDNN: 50,
                restingHR: 55,
                sleepTotalMinutes: 480
            )
        }
        let baseline = RecoveryEngine(workouts: [], healthMetrics: health, now: now).report()
        let checkedIn = RecoveryEngine(workouts: [], healthMetrics: health, todayCheckinTags: ["sore"], now: now).report()
        let sickCheckin = RecoveryEngine(workouts: [], healthMetrics: health, todayCheckinTags: ["sick"], now: now).report()

        #expect(checkedIn.displayScore == baseline.displayScore)
        #expect(checkedIn.action == baseline.action)
        #expect(checkedIn.reasonChips.contains { $0.text == "Felt: sore" })
        #expect(sickCheckin.displayScore == baseline.displayScore)
        #expect(sickCheckin.action == .deloadRecover)
    }
}
