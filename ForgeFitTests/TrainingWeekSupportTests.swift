import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct TrainingWeekSupportTests {
    private let userID = ForgeFitDemo.userID

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func workout(on date: Date, completed: Bool = true, deleted: Bool = false) -> WorkoutModel {
        let workout = WorkoutModel(
            userID: userID,
            startedAt: date,
            endedAt: completed ? date.addingTimeInterval(3_600) : nil
        )
        if deleted { workout.deletedAt = date.addingTimeInterval(4_000) }
        return workout
    }

    @Test func weekAlwaysRunsSundayThroughSaturday() {
        let wednesday = date(2026, 7, 15)
        let interval = TrainingWeekSupport.interval(containing: wednesday, calendar: calendar)
        #expect(calendar.component(.weekday, from: interval.start) == 1)
        #expect(interval.start == date(2026, 7, 12, hour: 0))
        #expect(interval.end == date(2026, 7, 19, hour: 0))
    }

    @Test func completionStripMarksOnlyCompletedNonDeletedWorkouts() {
        let wednesday = date(2026, 7, 15)
        let days = TrainingWeekSupport.days(
            workouts: [
                workout(on: date(2026, 7, 12)),
                workout(on: date(2026, 7, 12, hour: 18)),
                workout(on: date(2026, 7, 14), completed: false),
                workout(on: date(2026, 7, 16), deleted: true),
                workout(on: date(2026, 7, 18)),
            ],
            containing: wednesday,
            calendar: calendar
        )

        #expect(days.map(\.symbol) == ["S", "M", "T", "W", "T", "F", "S"])
        #expect(days.map(\.hasWorkout) == [true, false, false, false, false, false, true])
    }

    @Test func headlineTotalsUseTheSameSundayBoundary() {
        let monday = date(2026, 7, 13)
        let workouts = [
            workout(on: date(2026, 7, 12)),
            workout(on: date(2026, 7, 11)),
        ]
        let totals = TrainingAnalytics(workouts: workouts, exercises: [], calendar: calendar, now: monday).thisWeek()
        #expect(totals.workoutCount == 1)
    }
}
