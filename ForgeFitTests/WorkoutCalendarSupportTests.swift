import Foundation
import Testing
@testable import ForgeFit

/// The pure logic behind the Profile workout calendar: month-grid layout,
/// local-day grouping keys, and per-workout type classification.
struct WorkoutCalendarSupportTests {
    /// Fixed environment so assertions don't depend on the machine running
    /// the tests: Gregorian, UTC, Sunday-first.
    private var utcSundayFirst: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: gridDays

    /// July 2026 starts on a Wednesday: 3 leading blanks under a
    /// Sunday-first week, then 31 day cells.
    @Test func gridAlignsFirstDayUnderItsWeekday() {
        let cal = utcSundayFirst
        let cells = WorkoutCalendarSupport.gridDays(forMonthContaining: date(2026, 7, 15, calendar: cal), calendar: cal)
        #expect(cells.count == 3 + 31)
        #expect(cells.prefix(3).allSatisfy { $0 == nil })
        #expect(cells[3] == cal.startOfDay(for: date(2026, 7, 1, calendar: cal)))
        #expect(cells.last! == cal.startOfDay(for: date(2026, 7, 31, calendar: cal)))
    }

    /// Same month under a Monday-first week has 2 leading blanks.
    @Test func gridRespectsFirstWeekday() {
        var cal = utcSundayFirst
        cal.firstWeekday = 2
        let cells = WorkoutCalendarSupport.gridDays(forMonthContaining: date(2026, 7, 15, calendar: cal), calendar: cal)
        #expect(cells.count == 2 + 31)
        #expect(cells[2] == cal.startOfDay(for: date(2026, 7, 1, calendar: cal)))
    }

    /// February in a leap year — and a month whose 1st IS the first weekday
    /// (Feb 2026 starts on a Sunday) — has no leading blanks.
    @Test func gridHandlesLeapFebruaryWithNoLeadingBlanks() {
        let cal = utcSundayFirst
        let cells = WorkoutCalendarSupport.gridDays(forMonthContaining: date(2028, 2, 10, calendar: cal), calendar: cal)
        #expect(cells.count == 2 + 29)   // Feb 2028 starts Tuesday, 29 days
        let feb2026 = WorkoutCalendarSupport.gridDays(forMonthContaining: date(2026, 2, 10, calendar: cal), calendar: cal)
        #expect(feb2026.first! != nil)   // Feb 1 2026 is a Sunday — no blanks
        #expect(feb2026.count == 28)
    }

    // MARK: monthStart / dayKey

    @Test func monthStartIsMidnightOfTheFirst() {
        let cal = utcSundayFirst
        let start = WorkoutCalendarSupport.monthStart(containing: date(2026, 12, 31, hour: 23, calendar: cal), calendar: cal)
        #expect(start == date(2026, 12, 1, hour: 0, calendar: cal))
    }

    /// The grouping key is LOCAL midnight: a 11:30 PM New York session groups
    /// into that New York day, even though it's already the next day in UTC.
    @Test func dayKeyGroupsByLocalDayNotRawTimestamp() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let lateSession = date(2026, 7, 4, hour: 23, calendar: newYork)   // July 5, 03:00 UTC

        let localKey = WorkoutCalendarSupport.dayKey(for: lateSession, calendar: newYork)
        #expect(localKey == date(2026, 7, 4, hour: 0, calendar: newYork))

        let utcKey = WorkoutCalendarSupport.dayKey(for: lateSession, calendar: utcSundayFirst)
        #expect(utcKey == date(2026, 7, 5, hour: 0, calendar: utcSundayFirst))
    }

    /// Two workouts on the same local day share one key; a workout the next
    /// morning gets its own.
    @Test func multipleWorkoutsOnOneDayShareAKey() {
        let cal = utcSundayFirst
        let morning = WorkoutCalendarSupport.dayKey(for: date(2026, 7, 4, hour: 9, calendar: cal), calendar: cal)
        let evening = WorkoutCalendarSupport.dayKey(for: date(2026, 7, 4, hour: 18, calendar: cal), calendar: cal)
        let nextDay = WorkoutCalendarSupport.dayKey(for: date(2026, 7, 5, hour: 9, calendar: cal), calendar: cal)
        #expect(morning == evening)
        #expect(morning != nextDay)
    }

    // MARK: workoutKind

    @Test func classifiesStrengthCardioAndMixed() {
        let strength = UUID(), cardioExercise = UUID()

        #expect(WorkoutCalendarSupport.workoutKind(
            exerciseIDs: [strength], cardioLinkedExerciseIDs: [], cardioSessionCount: 0) == .strength)

        #expect(WorkoutCalendarSupport.workoutKind(
            exerciseIDs: [cardioExercise], cardioLinkedExerciseIDs: [cardioExercise], cardioSessionCount: 1) == .cardio)

        #expect(WorkoutCalendarSupport.workoutKind(
            exerciseIDs: [strength, cardioExercise], cardioLinkedExerciseIDs: [cardioExercise], cardioSessionCount: 1) == .mixed)

        // Legacy unlinked cardio alongside strength is still a mixed session.
        #expect(WorkoutCalendarSupport.workoutKind(
            exerciseIDs: [strength], cardioLinkedExerciseIDs: [], cardioSessionCount: 1) == .mixed)
    }

    // MARK: weekday symbols

    @Test func weekdaySymbolsRotateToFirstWeekday() {
        let sundayFirst = WorkoutCalendarSupport.orderedWeekdaySymbols(utcSundayFirst)
        #expect(sundayFirst.count == 7)
        #expect(sundayFirst.first == utcSundayFirst.veryShortWeekdaySymbols[0])

        var mondayFirst = utcSundayFirst
        mondayFirst.firstWeekday = 2
        let rotated = WorkoutCalendarSupport.orderedWeekdaySymbols(mondayFirst)
        #expect(rotated.first == mondayFirst.veryShortWeekdaySymbols[1])
        #expect(rotated.last == mondayFirst.veryShortWeekdaySymbols[0])
    }
}
