import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ExperimentLifecycleServiceTests {
    @Test func resultsNotificationRouteContainsOnlyTheOpaqueExperimentID() {
        let id = UUID()
        let url = ExperimentNotificationRoute.resultsURL(experimentID: id)

        #expect(url.scheme == "forgefit")
        #expect(url.host == "experiment")
        #expect(url.pathComponents == ["/", id.uuidString, "results"])
        #expect(!url.absoluteString.localizedCaseInsensitiveContains("supplement"))
    }

    @Test func reconcileCompletesAtScheduledBoundary() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let end = now.addingTimeInterval(-60)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Eight weeks",
            startedAt: end.addingTimeInterval(-8 * 7 * 86_400),
            plannedEndAt: end
        )
        context.insert(experiment)
        try context.save()

        let result = try ExperimentLifecycleService.reconcile(in: context, now: now)

        #expect(result.completedIDs == [experiment.id])
        #expect(experiment.state == .completed)
        #expect(experiment.endedAt == end)
        #expect(try ExperimentLifecycleService.activeExperiment(in: context, now: now) == nil)
    }

    @Test func futureExperimentRemainsActive() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Current",
            startedAt: now.addingTimeInterval(-3_600),
            plannedEndAt: now.addingTimeInterval(3_600)
        )
        context.insert(experiment)
        try context.save()

        let result = try ExperimentLifecycleService.reconcile(in: context, now: now)

        #expect(result.completedIDs.isEmpty)
        #expect(result.duplicateActiveIDs.isEmpty)
        #expect(try ExperimentLifecycleService.activeExperiment(in: context, now: now)?.id == experiment.id)
    }

    @Test func duplicateActivesAreReportedWithoutDestroyingData() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let first = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "First",
            startedAt: now.addingTimeInterval(-7_200),
            plannedEndAt: now.addingTimeInterval(3_600)
        )
        let second = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Second",
            startedAt: now.addingTimeInterval(-3_600),
            plannedEndAt: now.addingTimeInterval(7_200)
        )
        context.insert(first)
        context.insert(second)
        try context.save()

        let result = try ExperimentLifecycleService.reconcile(in: context, now: now)

        #expect(result.duplicateActiveIDs == [second.id])
        #expect(first.isActive)
        #expect(second.isActive)
    }

    @Test func reminderRequestsAreBoundedAndNeverOutliveTheExperiment() throws {
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 1, hour: 9
        )))
        let end = try #require(calendar.date(byAdding: .weekOfYear, value: 12, to: start))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 6, hour: 12
        )))
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Bounded reminders",
            startedAt: start,
            plannedEndAt: end,
            timeZoneIdentifier: timeZone.identifier
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Daily",
            type: .boolean,
            cadence: .daily
        )

        let dates = ExperimentNotificationScheduler.reminderDates(
            experiment: experiment,
            trackers: [tracker],
            minutesAfterMidnight: 19 * 60,
            now: now,
            limit: 28
        )

        #expect(dates.count == 28)
        #expect(dates.allSatisfy { $0 > now && $0 < end })
        #expect(dates.allSatisfy {
            calendar.component(.hour, from: $0) == 19
        })
    }

    @Test func perWorkoutAndAnytimeTrackersDoNotCreateDailyNagReminders() {
        let now = Date()
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Workout only",
            startedAt: now.addingTimeInterval(-60),
            plannedEndAt: now.addingTimeInterval(7 * 86_400)
        )
        let trackers = [
            ExperimentTrackerModel(
                userID: ForgeFitDemo.userID,
                experimentID: experiment.id,
                label: "After training",
                type: .rating,
                cadence: .perWorkout
            ),
            ExperimentTrackerModel(
                userID: ForgeFitDemo.userID,
                experimentID: experiment.id,
                label: "Notes",
                type: .note,
                cadence: .anytime
            ),
        ]

        let dates = ExperimentNotificationScheduler.reminderDates(
            experiment: experiment,
            trackers: trackers,
            minutesAfterMidnight: 19 * 60,
            now: now,
            limit: 28
        )

        #expect(dates.isEmpty)
    }

    @Test func notificationScheduleSnapshotSurvivesManagedModelDeletion() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Private protocol",
            startedAt: now,
            plannedEndAt: now.addingTimeInterval(7 * 86_400),
            timeZoneIdentifier: "UTC",
            reminderEnabled: true,
            reminderTimeMinutes: 1_140
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Private tracker",
            type: .boolean,
            cadence: .daily
        )
        context.insert(experiment)
        context.insert(tracker)
        try context.save()

        let snapshot = ExperimentNotificationScheduler.ScheduleSnapshot(
            experiment: experiment,
            trackers: [tracker]
        )
        let experimentID = snapshot.experimentID
        context.delete(tracker)
        context.delete(experiment)
        try context.save()

        #expect(snapshot.experimentID == experimentID)
        #expect(snapshot.reminderEnabled)
        #expect(snapshot.reminderTimeMinutes == 1_140)
        #expect(snapshot.dueWeekdays == Set(1...7))
        #expect(snapshot.timeZoneIdentifier == "UTC")
    }
}
