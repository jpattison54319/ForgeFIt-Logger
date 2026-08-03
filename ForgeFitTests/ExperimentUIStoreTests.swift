import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ExperimentUIStoreTests {
    @Test
    func expectedCoverageUsesTheTrackerDefinitionLifetime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let start = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1)
        ))
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: UUID(),
            label: "Daily response",
            type: .rating,
            cadence: .daily,
            createdAt: try #require(calendar.date(
                from: DateComponents(year: 2026, month: 1, day: 4)
            )),
            archivedAt: try #require(calendar.date(
                from: DateComponents(year: 2026, month: 1, day: 7)
            ))
        )
        let end = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 1, day: 10)
        ))

        #expect(ExperimentTrackerSchedule.expectedOccurrences(
            for: tracker,
            start: start,
            end: end,
            workouts: [],
            calendar: calendar
        ) == 3)
    }

    @Test
    func restoringTrackerCreatesTwoDisjointDefinitionLifetimes() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let today = calendar.startOfDay(for: .now)
        let start = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let archivedAt = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let restoredAt = try #require(calendar.date(byAdding: .hour, value: 12, to: today))
        let end = try #require(calendar.date(byAdding: .day, value: 3, to: today))
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Versioned tracker",
            startedAt: start,
            plannedEndAt: end,
            timeZoneIdentifier: "UTC"
        )
        let original = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Morning energy",
            type: .rating,
            cadence: .daily,
            definitionVersion: 2,
            createdAt: start,
            updatedAt: archivedAt,
            archivedAt: archivedAt
        )
        context.insert(experiment)
        context.insert(original)
        try context.save()

        let restored = try ExperimentUIStore.restoreTrackerVersion(
            original,
            for: experiment,
            position: 1,
            in: context,
            now: restoredAt
        )

        #expect(original.archivedAt == archivedAt)
        #expect(restored.id != original.id)
        #expect(restored.createdAt == restoredAt)
        #expect(restored.archivedAt == nil)
        #expect(restored.definitionVersion == 3)
        #expect(ExperimentTrackerSchedule.expectedOccurrences(
            for: original,
            start: start,
            end: end,
            workouts: [],
            calendar: calendar
        ) == 2)
        #expect(ExperimentTrackerSchedule.expectedOccurrences(
            for: restored,
            start: start,
            end: end,
            workouts: [],
            calendar: calendar
        ) == 3)

        let gap = try #require(calendar.date(byAdding: .hour, value: 6, to: archivedAt))
        #expect(throws: ExperimentUIStoreError.trackerUnavailable) {
            try ExperimentUIStore.saveEntry(
                value: .rating(4),
                tracker: original,
                experiment: experiment,
                entries: [],
                observedAt: gap,
                in: context,
                calendar: calendar
            )
        }
        #expect(throws: ExperimentUIStoreError.trackerUnavailable) {
            try ExperimentUIStore.saveEntry(
                value: .rating(4),
                tracker: restored,
                experiment: experiment,
                entries: [],
                observedAt: gap,
                in: context,
                calendar: calendar
            )
        }
    }

    @Test
    func startEnforcesOneActiveExperimentAtTheStoreBoundary() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        var draft = ExperimentSetupDraft()
        draft.name = "First"
        _ = try ExperimentUIStore.start(draft: draft, in: context)

        draft.name = "Second"
        #expect(throws: ExperimentUIStoreError.activeExperimentExists) {
            try ExperimentUIStore.start(draft: draft, in: context)
        }
    }

    @Test
    func startRejectsAnActiveWorkoutEvenIfTheSetupScreenWasStale() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.insert(WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "In progress"
        ))
        try context.save()
        var draft = ExperimentSetupDraft()
        draft.name = "Blocked"

        #expect(throws: ExperimentUIStoreError.activeWorkoutExists) {
            try ExperimentUIStore.start(draft: draft, in: context)
        }
    }

    @Test
    func perWorkoutEntryRequiresAnIncludedCompletedWorkoutAndUsesItsStart() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let start = Date().addingTimeInterval(-3_600)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Workout response",
            startedAt: start,
            plannedEndAt: start.addingTimeInterval(7_200)
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Energy",
            type: .rating,
            cadence: .perWorkout,
            createdAt: start
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Lift",
            startedAt: start.addingTimeInterval(600),
            endedAt: start.addingTimeInterval(1_800)
        )
        context.insert(experiment)
        context.insert(tracker)
        context.insert(workout)
        try context.save()

        #expect(throws: ExperimentUIStoreError.workoutRequired) {
            try ExperimentUIStore.saveEntry(
                value: .rating(4),
                tracker: tracker,
                experiment: experiment,
                entries: [],
                observedAt: Date(),
                in: context
            )
        }

        let entry = try ExperimentUIStore.saveEntry(
            value: .rating(4),
            tracker: tracker,
            experiment: experiment,
            entries: [],
            observedAt: Date(),
            workoutID: workout.id,
            in: context
        )
        #expect(entry.workoutID == workout.id)
        #expect(entry.observedAt == workout.startedAt)
    }

    @Test
    func perWorkoutEntryRejectsAWorkoutBeforeTheTrackerExisted() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let start = Date().addingTimeInterval(-7_200)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "New tracker boundary",
            startedAt: start,
            plannedEndAt: start.addingTimeInterval(10_800)
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "After-workout response",
            type: .rating,
            cadence: .perWorkout,
            createdAt: start.addingTimeInterval(3_600)
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Earlier workout",
            startedAt: start.addingTimeInterval(1_800),
            endedAt: start.addingTimeInterval(2_400)
        )
        context.insert(experiment)
        context.insert(tracker)
        context.insert(workout)
        try context.save()

        #expect(throws: ExperimentUIStoreError.trackerUnavailable) {
            try ExperimentUIStore.saveEntry(
                value: .rating(4),
                tracker: tracker,
                experiment: experiment,
                entries: [],
                observedAt: workout.startedAt,
                workoutID: workout.id,
                in: context
            )
        }
    }

    @Test
    func entryValueMustMatchTheTrackerDefinition() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Choices",
            startedAt: Date().addingTimeInterval(-60),
            plannedEndAt: Date().addingTimeInterval(3_600)
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Dose",
            type: .choice,
            options: ["A", "B"],
            cadence: .anytime
        )
        context.insert(experiment)
        context.insert(tracker)
        try context.save()

        #expect(throws: ExperimentUIStoreError.invalidTrackerValue) {
            try ExperimentUIStore.saveEntry(
                value: .choice("C"),
                tracker: tracker,
                experiment: experiment,
                entries: [],
                observedAt: Date(),
                in: context
            )
        }
    }

    @Test
    func numericEditDraftRoundTripsStoredPrecision() {
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: UUID(),
            label: "Dose",
            type: .number,
            cadence: .daily
        )
        let draft = TrackerInputDraft(value: .number(0.125))

        #expect(draft.numberText == "0.125")
        #expect(draft.entryValue(for: tracker) == .number(0.125))
    }
}
