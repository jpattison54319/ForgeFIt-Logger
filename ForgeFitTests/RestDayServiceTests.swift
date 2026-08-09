import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct RestDayServiceTests {
    private let timeZone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }

    @Test func logsTodayOrAPastDateAtStartOfDay() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        let restDay = try RestDayService.log(
            date: date(2026, 8, 5, 20),
            workouts: [],
            in: context,
            now: date(2026, 8, 8),
            timeZone: timeZone
        )

        #expect(restDay.date == date(2026, 8, 5, 0))
        #expect(restDay.timeZoneIdentifier == timeZone.identifier)
        #expect(try context.fetch(FetchDescriptor<RestDayModel>()).count == 1)
    }

    @Test func rejectsFutureDatesAndDaysWithCompletedTraining() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            startedAt: date(2026, 8, 7, 8),
            endedAt: date(2026, 8, 7, 9)
        )

        #expect(throws: RestDayService.ServiceError.futureDate) {
            try RestDayService.log(
                date: date(2026, 8, 9),
                workouts: [],
                in: context,
                now: date(2026, 8, 8),
                timeZone: timeZone
            )
        }
        #expect(throws: RestDayService.ServiceError.trainingExists) {
            try RestDayService.log(
                date: date(2026, 8, 7),
                workouts: [workout],
                in: context,
                now: date(2026, 8, 8),
                timeZone: timeZone
            )
        }
    }

    @Test func removingThenLoggingAgainRevivesTheSameMarker() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let first = try RestDayService.log(
            date: date(2026, 8, 6),
            workouts: [],
            in: context,
            now: date(2026, 8, 8),
            timeZone: timeZone
        )
        try RestDayService.remove(first, in: context, now: date(2026, 8, 8, 13))
        #expect(first.deletedAt != nil)

        let revived = try RestDayService.log(
            date: date(2026, 8, 6),
            workouts: [],
            in: context,
            now: date(2026, 8, 8, 14),
            timeZone: timeZone
        )

        #expect(revived.id == first.id)
        #expect(revived.deletedAt == nil)
        #expect(try context.fetch(FetchDescriptor<RestDayModel>()).count == 1)
    }

    @Test func laterWorkoutCompletionAutomaticallyRemovesAConflict() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let restDay = try RestDayService.log(
            date: date(2026, 8, 6),
            workouts: [],
            in: context,
            now: date(2026, 8, 8),
            timeZone: timeZone
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            startedAt: date(2026, 8, 6, 18),
            endedAt: date(2026, 8, 6, 19)
        )
        context.insert(workout)
        try context.save()

        try RestDayService.removeWorkoutConflicts(
            in: context,
            now: date(2026, 8, 8, 15)
        )

        #expect(restDay.deletedAt == date(2026, 8, 8, 15))
    }
}
