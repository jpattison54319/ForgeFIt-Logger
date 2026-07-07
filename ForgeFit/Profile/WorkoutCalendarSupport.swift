import Foundation

/// Pure date/classification logic behind the Profile workout calendar: month
/// grid layout, local-day grouping keys, and the training-type marker for a
/// day cell. Calendar is always injected so tests control week start and
/// timezone.
enum WorkoutCalendarSupport {
    /// What a workout was, for the calendar's per-workout day markers.
    enum WorkoutKind {
        case strength, cardio, mixed
    }

    /// Same linkage inputs as `CardioBlockSupport.isMixedWorkout`: strength
    /// exercises are the ones no cardio session is linked to.
    static func workoutKind(
        exerciseIDs: [UUID],
        cardioLinkedExerciseIDs: Set<UUID>,
        cardioSessionCount: Int
    ) -> WorkoutKind {
        guard cardioSessionCount > 0 else { return .strength }
        let hasStrength = exerciseIDs.contains { !cardioLinkedExerciseIDs.contains($0) }
        return hasStrength ? .mixed : .cardio
    }

    /// Midnight of the first day of the month containing `date`.
    static func monthStart(containing date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// The grouping key for "which local day did this workout happen on" —
    /// local midnight, so a 11:58 PM session lands on the day the user lived.
    static func dayKey(for date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Cells for a month laid out on a 7-column week grid: leading nils align
    /// the 1st under its weekday column (respecting `calendar.firstWeekday`),
    /// then one Date per day of the month.
    static func gridDays(forMonthContaining date: Date, calendar: Calendar) -> [Date?] {
        let start = monthStart(containing: date, calendar: calendar)
        guard let dayRange = calendar.range(of: .day, in: .month, for: start) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        var cells = [Date?](repeating: nil, count: leading)
        for offset in 0..<dayRange.count {
            cells.append(calendar.date(byAdding: .day, value: offset, to: start))
        }
        return cells
    }

    /// Weekday header symbols rotated so the calendar's first weekday leads.
    static func orderedWeekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        guard symbols.count == 7, (0..<7).contains(shift) else { return symbols }
        return Array(symbols[shift...] + symbols[..<shift])
    }
}
