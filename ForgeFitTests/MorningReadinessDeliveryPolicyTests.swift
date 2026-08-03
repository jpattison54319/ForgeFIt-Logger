import Foundation
import Testing
@testable import ForgeFit

struct MorningReadinessDeliveryPolicyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func completeScoreBeforePreferredTimeSchedulesForSeven() throws {
        let now = date(hour: 6)
        let fireDate = try #require(MorningReadinessDeliveryPolicy.fireDate(
            now: now,
            calendar: calendar,
            hasCompleteSleep: true,
            hasDailyScore: true
        ))

        #expect(fireDate == date(hour: 7))
    }

    @Test
    func completeScoreAfterSevenSchedulesImmediately() throws {
        let now = date(hour: 8, minute: 15)
        let fireDate = try #require(MorningReadinessDeliveryPolicy.fireDate(
            now: now,
            calendar: calendar,
            hasCompleteSleep: true,
            hasDailyScore: true
        ))

        #expect(fireDate == now.addingTimeInterval(2))
    }

    @Test
    func completeScoreJustBeforeCutoffStillSchedulesImmediately() throws {
        let now = date(hour: 10, minute: 29)
        let fireDate = try #require(MorningReadinessDeliveryPolicy.fireDate(
            now: now,
            calendar: calendar,
            hasCompleteSleep: true,
            hasDailyScore: true
        ))

        #expect(fireDate == now.addingTimeInterval(2))
    }

    @Test
    func missingSleepNeverSchedulesAnIncompleteNotification() {
        let fireDate = MorningReadinessDeliveryPolicy.fireDate(
            now: date(hour: 8),
            calendar: calendar,
            hasCompleteSleep: false,
            hasDailyScore: true
        )

        #expect(fireDate == nil)
    }

    @Test
    func missingDailyScoreNeverSchedulesASevenDayFallback() {
        let fireDate = MorningReadinessDeliveryPolicy.fireDate(
            now: date(hour: 8),
            calendar: calendar,
            hasCompleteSleep: true,
            hasDailyScore: false
        )

        #expect(fireDate == nil)
    }

    @Test
    func completeScoreAtOrAfterCutoffDoesNotNotify() {
        for now in [date(hour: 10, minute: 30), date(hour: 11)] {
            let fireDate = MorningReadinessDeliveryPolicy.fireDate(
                now: now,
                calendar: calendar,
                hasCompleteSleep: true,
                hasDailyScore: true
            )

            #expect(fireDate == nil)
        }
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 30,
            hour: hour,
            minute: minute
        ))!
    }
}
