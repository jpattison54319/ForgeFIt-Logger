import ForgeData
import Foundation

/// One Sunday-to-Saturday training week shared by Home's calendar strip and
/// its headline totals. This intentionally ignores the device locale's first
/// weekday because the product presents Sunday first everywhere.
enum TrainingWeekSupport {
    struct Day: Identifiable, Equatable {
        let date: Date
        let symbol: String
        let hasWorkout: Bool

        var id: Date { date }
    }

    private static let symbols = ["S", "M", "T", "W", "T", "F", "S"]

    static func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        let daysSinceSunday = max(0, calendar.component(.weekday, from: day) - 1)
        let start = calendar.date(byAdding: .day, value: -daysSinceSunday, to: day) ?? day
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func days(
        workouts: [WorkoutModel],
        containing date: Date,
        calendar: Calendar = .current
    ) -> [Day] {
        let week = interval(containing: date, calendar: calendar)
        let completedDays = Set(workouts.compactMap { workout -> Date? in
            guard workout.endedAt != nil, workout.deletedAt == nil,
                  week.contains(workout.startedAt) else { return nil }
            return calendar.startOfDay(for: workout.startedAt)
        })

        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            return Day(date: day, symbol: symbols[offset], hasWorkout: completedDays.contains(day))
        }
    }

    static func rangeLabel(containing date: Date, calendar: Calendar = .current) -> String {
        let week = interval(containing: date, calendar: calendar)
        let lastDay = calendar.date(byAdding: .day, value: -1, to: week.end) ?? week.end
        let start = week.start.formatted(.dateTime.month(.abbreviated).day())
        let end = lastDay.formatted(.dateTime.month(.abbreviated).day())
        return "\(start) – \(end)"
    }
}
