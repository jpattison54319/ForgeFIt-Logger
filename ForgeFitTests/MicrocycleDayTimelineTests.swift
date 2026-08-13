import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleDayTimelineTests {
    private let timeZone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: day,
            hour: hour
        ))!
    }

    @Test func todayStaysCurrentAfterItsWorkoutCompletes() throws {
        let routineID = UUID()
        let window = makeWindow(index: 0, routineID: routineID, startDay: 1)
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: date(1),
            endedAt: date(1, 13)
        )

        let days = MicrocycleDayTimeline.days(
            in: window,
            workouts: [workout],
            restDays: [],
            now: date(1, 14)
        )

        #expect(days.count == 10)
        #expect(days[0].status == .trained)
        #expect(days[0].routineMarkers == ["A"])
        #expect(days[0].isToday)
        #expect(days[1].status == .empty)
        #expect(!days[1].isToday)
        #expect(days.dropFirst().allSatisfy { $0.status == .empty })
    }

    @Test func skippedDaysStayUnloggedWhileCurrentDayFollowsTheCalendar() throws {
        let routineID = UUID()
        let window = makeWindow(index: 0, routineID: routineID, startDay: 1)
        let firstDayWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: date(1),
            endedAt: date(1, 13)
        )

        let days = MicrocycleDayTimeline.days(
            in: window,
            workouts: [firstDayWorkout],
            restDays: [],
            now: date(3)
        )

        #expect(days[0].status == .trained)
        #expect(days[1].status == .empty)
        #expect(!days[1].isToday)
        #expect(days[2].status == .empty)
        #expect(days[2].isToday)
        #expect(days.count(where: \.isToday) == 1)
    }

    @Test func completedDayShowsTheLetterOfTheRoutinePerformed() throws {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let window = MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: UUID(),
            folderID: UUID(),
            folderName: "Three Day",
            index: 0,
            startsAt: date(1, 0),
            endsAt: date(11, 0),
            timeZoneIdentifier: timeZone.identifier,
            routines: [
                .init(id: firstID, name: "Upper", position: 0),
                .init(id: secondID, name: "Lower", position: 1),
                .init(id: thirdID, name: "Conditioning", position: 2)
            ]
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: thirdID,
            startedAt: date(1),
            endedAt: date(1, 13)
        )

        let days = MicrocycleDayTimeline.days(
            in: window,
            workouts: [workout],
            restDays: [],
            now: date(1, 14)
        )

        #expect(days[0].status == .trained)
        #expect(days[0].routineMarkers == ["C"])
        #expect(days[1].status == .empty)
        #expect(days[1].routineMarkers.isEmpty)
    }

    @Test func aNewWindowRestartsAtDayOneAndTheCompletedWindowStaysFinished() throws {
        let routineID = UUID()
        let trackingID = UUID()
        let completedWindow = makeWindow(
            trackingID: trackingID,
            index: 0,
            routineID: routineID,
            startDay: 1
        )
        let nextWindow = makeWindow(
            trackingID: trackingID,
            index: 1,
            routineID: routineID,
            startDay: 11
        )
        let lastDayWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: date(10),
            endedAt: date(10, 13)
        )

        let completedDays = MicrocycleDayTimeline.days(
            in: completedWindow,
            workouts: [lastDayWorkout],
            restDays: [],
            now: date(10, 14)
        )
        let nextDays = MicrocycleDayTimeline.days(
            in: nextWindow,
            workouts: [lastDayWorkout],
            restDays: [],
            now: date(11)
        )

        #expect(completedDays[9].status == .trained)
        #expect(completedDays[9].isToday)
        #expect(nextDays[0].status == .empty)
        #expect(nextDays[0].isToday)
        #expect(nextDays.dropFirst().allSatisfy { $0.status == .empty })
    }

    private func makeWindow(
        trackingID: UUID = UUID(),
        index: Int,
        routineID: UUID,
        startDay: Int
    ) -> MicrocycleWindowModel {
        MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: trackingID,
            folderID: UUID(),
            folderName: "Upper Lower",
            index: index,
            startsAt: date(startDay, 0),
            endsAt: date(startDay + 10, 0),
            timeZoneIdentifier: timeZone.identifier,
            routines: [.init(id: routineID, name: "Upper", position: 0)]
        )
    }
}
