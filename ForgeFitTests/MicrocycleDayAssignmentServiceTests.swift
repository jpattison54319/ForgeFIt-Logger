import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleDayAssignmentServiceTests {
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

    @Test func backfillLinksRealWorkoutRemovesRestConflictAndUpdatesProgress() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let routineID = UUID()
        let window = makeWindow(
            routineID: routineID,
            startsAt: date(2026, 8, 1, 0),
            endsAt: date(2026, 8, 11, 0)
        )
        let originalDate = date(2026, 7, 29)
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            title: "Upper",
            startedAt: originalDate,
            endedAt: date(2026, 7, 29, 13)
        )
        let restDay = RestDayModel(
            userID: ForgeFitDemo.userID,
            date: date(2026, 8, 2, 0),
            timeZoneIdentifier: timeZone.identifier
        )
        context.insert(window)
        context.insert(workout)
        context.insert(restDay)
        try context.save()

        #expect(MicrocycleDayAssignmentService.eligibleWorkouts(
            for: date(2026, 8, 2),
            in: window,
            windows: [window],
            workouts: [workout],
            now: date(2026, 8, 8)
        ).map(\.id) == [workout.id])

        try MicrocycleDayAssignmentService.assign(
            workout,
            to: date(2026, 8, 2),
            in: window,
            windows: [window],
            workouts: [workout],
            restDays: [restDay],
            context: context,
            now: date(2026, 8, 8)
        )

        let assignment = try #require(window.dayAssignments.first)
        #expect(assignment.workoutID == workout.id)
        #expect(assignment.day == date(2026, 8, 2, 0))
        #expect(workout.startedAt == originalDate)
        #expect(restDay.deletedAt == date(2026, 8, 8))

        let progress = MicrocycleTrackingService.progress(
            for: window,
            windows: [window],
            workouts: [workout]
        )
        #expect(progress.completedCount == 1)
        #expect(progress.routines.first?.workoutID == workout.id)
        #expect(progress.routines.first?.completedAt == date(2026, 8, 2, 0))

        let dayRecords = MicrocycleDayAssignmentService.dayWorkouts(
            on: date(2026, 8, 2),
            in: window,
            workouts: [workout]
        )
        #expect(dayRecords.map(\.id) == [workout.id])
        #expect(dayRecords.first?.isBackfilled == true)

        try MicrocycleDayAssignmentService.remove(
            assignment,
            from: window,
            context: context,
            now: date(2026, 8, 9)
        )
        #expect(window.dayAssignments.isEmpty)
        #expect(MicrocycleTrackingService.progress(
            for: window,
            windows: [window],
            workouts: [workout]
        ).completedCount == 0)
    }

    @Test func pickerOffersOnlyUncreditedCompletedWorkoutsForDueRoutines() throws {
        let routineID = UUID()
        let trackingID = UUID()
        let firstWindow = makeWindow(
            trackingID: trackingID,
            index: 0,
            routineID: routineID,
            startsAt: date(2026, 8, 1, 0),
            endsAt: date(2026, 8, 11, 0)
        )
        let currentWindow = makeWindow(
            trackingID: trackingID,
            index: 1,
            routineID: routineID,
            startsAt: date(2026, 8, 11, 0),
            endsAt: date(2026, 8, 21, 0)
        )
        let alreadyCredited = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            title: "Upper",
            startedAt: date(2026, 8, 2),
            endedAt: date(2026, 8, 2, 13)
        )
        let available = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            title: "Upper",
            startedAt: date(2026, 7, 29),
            endedAt: date(2026, 7, 29, 13)
        )
        let incomplete = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            title: "Upper",
            startedAt: date(2026, 7, 28)
        )
        let wrongRoutine = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: UUID(),
            title: "Other",
            startedAt: date(2026, 7, 27),
            endedAt: date(2026, 7, 27, 13)
        )
        let workouts = [alreadyCredited, available, incomplete, wrongRoutine]

        let candidates = MicrocycleDayAssignmentService.eligibleWorkouts(
            for: date(2026, 8, 12),
            in: currentWindow,
            windows: [firstWindow, currentWindow],
            workouts: workouts,
            now: date(2026, 8, 15)
        )

        #expect(candidates.map(\.id) == [available.id])
    }

    @Test func futureDaysCannotBeBackfilled() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let routineID = UUID()
        let window = makeWindow(
            routineID: routineID,
            startsAt: date(2026, 8, 1, 0),
            endsAt: date(2026, 8, 11, 0)
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: date(2026, 7, 29),
            endedAt: date(2026, 7, 29, 13)
        )

        #expect(throws: MicrocycleDayAssignmentService.ServiceError.futureDay) {
            try MicrocycleDayAssignmentService.assign(
                workout,
                to: date(2026, 8, 8),
                in: window,
                windows: [window],
                workouts: [workout],
                restDays: [],
                context: context,
                now: date(2026, 8, 7)
            )
        }
    }

    private func makeWindow(
        trackingID: UUID = UUID(),
        index: Int = 0,
        routineID: UUID,
        startsAt: Date,
        endsAt: Date
    ) -> MicrocycleWindowModel {
        MicrocycleWindowModel(
            userID: ForgeFitDemo.userID,
            trackingID: trackingID,
            folderID: UUID(),
            folderName: "Upper Lower",
            index: index,
            startsAt: startsAt,
            endsAt: endsAt,
            timeZoneIdentifier: timeZone.identifier,
            routines: [.init(id: routineID, name: "Upper", position: 0)]
        )
    }
}
