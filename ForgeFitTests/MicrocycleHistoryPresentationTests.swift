import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleHistoryPresentationTests {
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

    @Test func restartOfTheSameFolderCreatesSeparateHistoryParents() throws {
        let folderID = UUID()
        let first = tracking(
            folderID: folderID,
            stateRaw: "ended",
            endedAt: date(8),
            createdAt: date(1)
        )
        let second = tracking(
            folderID: folderID,
            stateRaw: "active",
            endedAt: nil,
            createdAt: date(9)
        )
        let firstWindow = window(tracking: first, index: 0, startDay: 1)
        let secondWindow = window(tracking: second, index: 0, startDay: 9)

        let runs = MicrocycleHistoryPresentation.runs(
            trackings: [first, second],
            windows: [firstWindow, secondWindow],
            workouts: [],
            now: date(10)
        )

        #expect(runs.count == 2)
        #expect(runs.map(\.trackingID) == [second.id, first.id])
        #expect(runs.allSatisfy { $0.folderName == "Strength Block" })
        #expect(runs[0].isActive)
        #expect(!runs[1].isActive)
        #expect(runs[0].windows.map(\.windowID) == [secondWindow.id])
        #expect(runs[1].windows.map(\.windowID) == [firstWindow.id])
        #expect(MicrocycleHistoryPresentation.hasStoppedRun([first, second]))
    }

    @Test func profileHistoryAvailabilityRequiresANonDeletedEndedRun() {
        let active = tracking(
            stateRaw: "active",
            endedAt: nil,
            createdAt: date(1)
        )
        let deletedEnded = tracking(
            stateRaw: "ended",
            endedAt: date(3),
            createdAt: date(1)
        )
        deletedEnded.deletedAt = date(4)

        #expect(!MicrocycleHistoryPresentation.hasStoppedRun([active]))
        #expect(!MicrocycleHistoryPresentation.hasStoppedRun([active, deletedEnded]))
    }

    @Test func stoppedWindowClipsDaysAndIgnoresWorkoutsCompletedAfterStop() throws {
        let tracking = tracking(
            stateRaw: "ended",
            endedAt: date(3, 15),
            createdAt: date(1, 8)
        )
        let firstRoutineID = UUID()
        let secondRoutineID = UUID()
        let window = window(
            tracking: tracking,
            index: 0,
            startDay: 1,
            routines: [
                .init(id: firstRoutineID, name: "Upper", position: 0),
                .init(id: secondRoutineID, name: "Lower", position: 1),
            ]
        )
        let beforeStop = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: firstRoutineID,
            startedAt: date(2, 10),
            endedAt: date(2, 11),
            createdAt: date(2, 9),
            updatedAt: date(2, 11)
        )
        let afterStop = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: secondRoutineID,
            startedAt: date(3, 16),
            endedAt: date(3, 17),
            createdAt: date(3, 16),
            updatedAt: date(3, 17)
        )

        let presentation = try #require(
            MicrocycleHistoryPresentation.windowPresentation(
                tracking: tracking,
                window: window,
                windows: [window],
                workouts: [beforeStop, afterStop],
                now: date(5)
            )
        )
        let days = MicrocycleHistoryPresentation.days(
            tracking: tracking,
            window: window,
            windows: [window],
            workouts: [beforeStop, afterStop],
            restDays: [],
            now: date(5)
        )

        #expect(presentation.state == .stopped(day: 3, total: 7))
        #expect(presentation.progress.completedCount == 1)
        #expect(presentation.progress.requiredCount == 2)
        #expect(days.count == 3)
        #expect(days[1].status == .trained)
        #expect(days[1].routineMarkers == ["A"])
        #expect(days[2].status == .empty)
    }

    @Test func assignmentCreatedAfterStopCannotRewriteStoppedHistory() throws {
        let tracking = tracking(
            stateRaw: "ended",
            endedAt: date(3, 15),
            createdAt: date(1, 8)
        )
        let routineID = UUID()
        let window = window(
            tracking: tracking,
            index: 0,
            startDay: 1,
            routines: [.init(id: routineID, name: "Upper", position: 0)]
        )
        let beforeWindow = try #require(calendar.date(
            byAdding: .day,
            value: -1,
            to: date(1, 0)
        ))
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: beforeWindow,
            endedAt: beforeWindow.addingTimeInterval(3_600),
            createdAt: beforeWindow,
            updatedAt: beforeWindow.addingTimeInterval(3_600)
        )
        window.dayAssignments = [
            MicrocycleDayAssignment(
                day: date(2, 0),
                workoutID: workout.id,
                assignedAt: date(4)
            )
        ]

        let presentation = try #require(
            MicrocycleHistoryPresentation.windowPresentation(
                tracking: tracking,
                window: window,
                windows: [window],
                workouts: [workout],
                now: date(5)
            )
        )

        #expect(presentation.progress.completedCount == 0)
        #expect(MicrocycleHistoryPresentation.dayWorkouts(
            on: date(2),
            tracking: tracking,
            window: window,
            windows: [window],
            workouts: [workout],
            now: date(5)
        ).isEmpty)
    }

    @Test func completedWindowRetainsItsFullScheduledRange() throws {
        let tracking = tracking(
            stateRaw: "ended",
            endedAt: date(12),
            createdAt: date(1, 8)
        )
        let routineID = UUID()
        let window = window(
            tracking: tracking,
            index: 0,
            startDay: 1,
            routines: [.init(id: routineID, name: "Upper", position: 0)]
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: date(7, 10),
            endedAt: date(7, 11),
            createdAt: date(7, 9),
            updatedAt: date(7, 11)
        )

        let presentation = try #require(
            MicrocycleHistoryPresentation.windowPresentation(
                tracking: tracking,
                window: window,
                windows: [window],
                workouts: [workout],
                now: date(13)
            )
        )
        let days = MicrocycleHistoryPresentation.days(
            tracking: tracking,
            window: window,
            windows: [window],
            workouts: [workout],
            restDays: [],
            now: date(13)
        )

        #expect(presentation.state == .finished)
        #expect(presentation.progress.isComplete)
        #expect(days.count == 7)
        #expect(days[6].status == .trained)
    }

    @Test func midnightStopTreatsThePreviousDayAsTheLastTrackedDay() throws {
        let tracking = tracking(
            stateRaw: "ended",
            endedAt: date(3, 0),
            createdAt: date(1, 8)
        )
        let window = window(tracking: tracking, index: 0, startDay: 1)

        let presentation = MicrocycleHistoryPresentation.windowPresentation(
            tracking: tracking,
            window: window,
            windows: [window],
            workouts: [],
            now: date(5)
        )

        #expect(presentation?.state == .stopped(day: 2, total: 7))
        #expect(presentation?.visibleEndsAt == date(3, 0).addingTimeInterval(-1))
    }

    @Test func endedStateWithoutTimestampUsesItsLastUpdateAsTheCutoff() throws {
        let tracking = tracking(
            stateRaw: "ended",
            endedAt: nil,
            createdAt: date(1, 8)
        )
        tracking.updatedAt = date(3, 15)
        let routineID = UUID()
        let window = window(
            tracking: tracking,
            index: 0,
            startDay: 1,
            routines: [.init(id: routineID, name: "Upper", position: 0)]
        )
        let laterWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: date(4, 10),
            endedAt: date(4, 11),
            createdAt: date(4, 9),
            updatedAt: date(4, 11)
        )

        let presentation = try #require(
            MicrocycleHistoryPresentation.windowPresentation(
                tracking: tracking,
                window: window,
                windows: [window],
                workouts: [laterWorkout],
                now: date(8)
            )
        )

        #expect(presentation.state == .stopped(day: 3, total: 7))
        #expect(presentation.progress.completedCount == 0)
    }

    @Test func windowThatStartsAtTheStopBoundaryIsNotPartOfHistory() {
        let tracking = tracking(
            stateRaw: "ended",
            endedAt: date(8, 0),
            createdAt: date(1, 8)
        )
        let futureWindow = window(tracking: tracking, index: 1, startDay: 8)

        #expect(MicrocycleHistoryPresentation.windowPresentation(
            tracking: tracking,
            window: futureWindow,
            windows: [futureWindow],
            workouts: [],
            now: date(9)
        ) == nil)
    }

    private func tracking(
        folderID: UUID = UUID(),
        stateRaw: String,
        endedAt: Date?,
        createdAt: Date
    ) -> MicrocycleTrackingModel {
        MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: folderID,
            folderName: "Strength Block",
            anchorDate: date(1, 0),
            durationDays: 7,
            timeZoneIdentifier: timeZone.identifier,
            stateRaw: stateRaw,
            endedAt: endedAt,
            createdAt: createdAt,
            updatedAt: endedAt ?? createdAt
        )
    }

    private func window(
        tracking: MicrocycleTrackingModel,
        index: Int,
        startDay: Int,
        routines: [MicrocycleRoutineSnapshot] = []
    ) -> MicrocycleWindowModel {
        MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: tracking.id,
            folderID: tracking.folderID,
            folderName: tracking.folderName,
            index: index,
            startsAt: date(startDay, 0),
            endsAt: date(startDay + 7, 0),
            timeZoneIdentifier: timeZone.identifier,
            routines: routines,
            createdAt: tracking.createdAt,
            updatedAt: tracking.updatedAt
        )
    }
}
