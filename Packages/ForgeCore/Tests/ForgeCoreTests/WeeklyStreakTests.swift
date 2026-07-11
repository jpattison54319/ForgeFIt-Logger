import Foundation
import Testing
@testable import ForgeCore

struct WeeklyStreakTests {
    // Fixed reference: Wed 2026-07-08 12:00 UTC, ISO calendar (Mon week start)
    // so tests never drift with the runner's locale.
    private var calendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private var now: Date { date(2026, 7, 8, hour: 12) }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    /// n workouts inside the week containing `day`, on consecutive days.
    private func week(of day: Date, count: Int) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: day)!.start
        return (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start)!.addingTimeInterval(36_000) }
    }

    @Test func threeMetWeeksMakeAThreeWeekStreak() {
        var dates: [Date] = []
        for weeksAgo in 1...3 {
            let anchor = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: now)!
            dates += week(of: anchor, count: 3)
        }
        let result = WeeklyStreak.compute(workoutDates: dates, goalPerWeek: 3, calendar: calendar, now: now)
        #expect(result.weeks == 3)
        #expect(result.longestWeeks == 3)
        #expect(result.thisWeekCount == 0)
        #expect(result.frozenWeeks.isEmpty)
    }

    @Test func missedWeekSpendsTheFreezeAndStreakSurvives() {
        var dates: [Date] = []
        // Weeks -3 and -1 met, week -2 missed entirely.
        for weeksAgo in [1, 3] {
            let anchor = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: now)!
            dates += week(of: anchor, count: 3)
        }
        let result = WeeklyStreak.compute(workoutDates: dates, goalPerWeek: 3, calendar: calendar, now: now)
        #expect(result.weeks == 2)
        #expect(result.frozenWeeks.count == 1)
        #expect(result.freezesBanked == 0)   // started with 1, spent it
    }

    @Test func twoMissedWeeksWithOneTokenEndTheStreak() {
        var dates: [Date] = []
        for weeksAgo in [1, 4] {   // weeks -2 and -3 missed
            let anchor = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: now)!
            dates += week(of: anchor, count: 3)
        }
        let result = WeeklyStreak.compute(workoutDates: dates, goalPerWeek: 3, calendar: calendar, now: now)
        // Streak broke at the second gap; only last week counts now.
        #expect(result.weeks == 1)
    }

    @Test func fourMetWeeksEarnAToken() {
        var dates: [Date] = []
        for weeksAgo in 1...4 {
            let anchor = calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: now)!
            dates += week(of: anchor, count: 3)
        }
        let result = WeeklyStreak.compute(workoutDates: dates, goalPerWeek: 3, calendar: calendar, now: now)
        #expect(result.weeks == 4)
        #expect(result.freezesBanked == 2)   // starting 1 + earned 1
    }

    @Test func currentWeekCountsOnceGoalIsMet() {
        let dates = week(of: now, count: 3)
        let result = WeeklyStreak.compute(workoutDates: dates, goalPerWeek: 3, calendar: calendar, now: now)
        #expect(result.weeks == 1)
        #expect(result.thisWeekMet)
    }

    @Test func mustTrainTodayFlagsOnlyTheLastPossibleDays() {
        // Streak alive from last week; this week 0 of 3 done, now = Wednesday
        // → 5 days left (Wed–Sun) for 3 needed → no alarm yet.
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: now)!
        var result = WeeklyStreak.compute(
            workoutDates: week(of: lastWeek, count: 3), goalPerWeek: 3, calendar: calendar, now: now
        )
        #expect(!result.mustTrainToday)

        // Friday with 0 of 3 → exactly 3 days left (Fri/Sat/Sun) → alarm.
        let friday = date(2026, 7, 10, hour: 12)
        result = WeeklyStreak.compute(
            workoutDates: week(of: lastWeek, count: 3), goalPerWeek: 3, calendar: calendar, now: friday
        )
        #expect(result.mustTrainToday)
    }

    @Test func noHistoryMeansZeroStreakAndNoAlarm() {
        let result = WeeklyStreak.compute(workoutDates: [], goalPerWeek: 3, calendar: calendar, now: now)
        #expect(result.weeks == 0)
        #expect(!result.mustTrainToday)
        #expect(result.freezesBanked == 1)
    }
}
