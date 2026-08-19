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
    func trackerRetryIsExactAndLeavesUnrelatedPendingEditUncommitted() throws {
        enum ExpectedFailure: Error { case write }

        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let now = Date.now
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Tracker transaction",
            startedAt: now.addingTimeInterval(-60),
            plannedEndAt: now.addingTimeInterval(3_600)
        )
        context.insert(experiment)
        try context.save()

        context.insert(RoutineModel(userID: ForgeFitDemo.userID, name: "Pending elsewhere"))
        var draft = ExperimentSetupTrackerDraft()
        draft.label = "Energy"
        draft.kind = .rating
        draft.cadence = .daily

        #expect(throws: ExpectedFailure.write) {
            _ = try ExperimentUIStore.upsertTracker(
                draft,
                replacing: nil,
                for: experiment,
                in: context,
                now: now,
                scheduleNotifications: false
            ) { _ in
                throw ExpectedFailure.write
            }
        }
        let afterFailure = ModelContext(container)
        #expect(try afterFailure.fetch(FetchDescriptor<ExperimentTrackerModel>()).isEmpty)
        #expect(try afterFailure.fetch(FetchDescriptor<RoutineModel>()).isEmpty)
        #expect(context.hasChanges)

        let result = try ExperimentUIStore.upsertTracker(
            draft,
            replacing: nil,
            for: experiment,
            in: context,
            now: now,
            scheduleNotifications: false
        )
        #expect(result.trackers.map(\.label) == ["Energy"])
        #expect(context.hasChanges)

        let afterRetry = ModelContext(container)
        #expect(try afterRetry.fetch(FetchDescriptor<ExperimentTrackerModel>()).count == 1)
        #expect(try afterRetry.fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        try context.save()
        let afterUnrelatedSave = ModelContext(container)
        #expect(try afterUnrelatedSave.fetch(FetchDescriptor<ExperimentTrackerModel>()).count == 1)
        #expect(
            try afterUnrelatedSave.fetch(FetchDescriptor<RoutineModel>()).map(\.name)
                == ["Pending elsewhere"]
        )
    }

    @Test
    func cachedTrackersRefreshAfterIsolatedUpdateReorderAndArchive() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let now = Date.now
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Tracker refresh",
            startedAt: now.addingTimeInterval(-60),
            plannedEndAt: now.addingTimeInterval(3_600),
            reminderEnabled: true,
            reminderTimeMinutes: 19 * 60
        )
        let first = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Energy",
            type: .rating,
            cadence: .daily,
            position: 0,
            createdAt: now.addingTimeInterval(-60)
        )
        let second = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Notes",
            type: .note,
            cadence: .anytime,
            position: 1,
            createdAt: now.addingTimeInterval(-30)
        )
        context.insert(experiment)
        context.insert(first)
        context.insert(second)
        try context.save()

        context.insert(RoutineModel(userID: ForgeFitDemo.userID, name: "Still pending"))
        var draft = ExperimentSetupTrackerDraft()
        draft.label = "Morning energy"
        draft.kind = .rating
        draft.cadence = .daily
        let updated = try ExperimentUIStore.upsertTracker(
            draft,
            replacing: first.id,
            for: experiment,
            in: context,
            now: now,
            scheduleNotifications: false
        )
        #expect(updated.trackers.first(where: { $0.id == first.id })?.label == "Morning energy")
        #expect(first.label == "Morning energy")

        let reordered = try ExperimentUIStore.moveTracker(
            first,
            offset: 1,
            for: experiment,
            in: context,
            now: now.addingTimeInterval(1)
        )
        let positions = Dictionary(uniqueKeysWithValues: reordered.trackers.map { ($0.id, $0.position) })
        #expect(positions[first.id] == 1)
        #expect(positions[second.id] == 0)
        #expect(first.position == 1)
        #expect(second.position == 0)

        let archived = try ExperimentUIStore.archiveTracker(
            first,
            for: experiment,
            in: context,
            now: now.addingTimeInterval(2),
            scheduleNotifications: false
        )
        #expect(archived.trackers.first(where: { $0.id == first.id })?.archivedAt != nil)
        #expect(first.archivedAt != nil)
        #expect(!archived.reminderEnabled)

        #expect(context.hasChanges)
        let beforeUnrelatedSave = ModelContext(container)
        #expect(try beforeUnrelatedSave.fetch(FetchDescriptor<RoutineModel>()).isEmpty)
        try context.save()
        let afterUnrelatedSave = ModelContext(container)
        #expect(
            try afterUnrelatedSave.fetch(FetchDescriptor<RoutineModel>()).map(\.name)
                == ["Still pending"]
        )
        let persistedTrackers = try afterUnrelatedSave.fetch(FetchDescriptor<ExperimentTrackerModel>())
        #expect(persistedTrackers.first(where: { $0.id == first.id })?.label == "Morning energy")
        #expect(persistedTrackers.first(where: { $0.id == first.id })?.position == 1)
        #expect(persistedTrackers.first(where: { $0.id == first.id })?.archivedAt != nil)
        #expect(persistedTrackers.first(where: { $0.id == second.id })?.position == 0)
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
    func startFailureAndRetryDoNotCommitAnotherTabsPendingEdit() throws {
        struct InjectedFailure: Error {}

        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let pendingRoutine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Pending elsewhere"
        )
        context.insert(pendingRoutine)
        var draft = ExperimentSetupDraft()
        draft.name = "Isolated start"

        #expect(throws: InjectedFailure.self) {
            try ExperimentUIStore.start(
                draft: draft,
                in: context,
                save: { _ in throw InjectedFailure() }
            )
        }
        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentModel>()).isEmpty)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        let experiment = try ExperimentUIStore.start(draft: draft, in: context)
        #expect(experiment.name == "Isolated start")
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentModel>()).count == 1)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        try context.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).count == 1)
    }

    @Test
    func resultsMetadataFailureAndRetryDoNotCommitAnotherTabsPendingEdit() throws {
        struct InjectedFailure: Error {}

        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let now = Date.now
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Completed experiment",
            startedAt: now.addingTimeInterval(-7_200),
            plannedEndAt: now.addingTimeInterval(-3_600)
        )
        experiment.endedAt = now.addingTimeInterval(-3_600)
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Committed")
        context.insert(experiment)
        context.insert(routine)
        try context.save()
        routine.name = "Pending elsewhere"

        #expect(throws: InjectedFailure.self) {
            try ExperimentUIStore.markResultsViewed(
                experiment,
                in: context,
                now: now,
                save: { _ in throw InjectedFailure() }
            )
        }
        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentModel>()).first?.resultsViewedAt == nil)

        try ExperimentUIStore.markResultsViewed(experiment, in: context, now: now)
        #expect(experiment.resultsViewedAt == now)
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentModel>()).first?.resultsViewedAt == now)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        #expect(throws: InjectedFailure.self) {
            try ExperimentUIStore.updateSavedComparison(
                "comparison",
                for: experiment,
                in: context,
                now: now.addingTimeInterval(1),
                save: { _ in throw InjectedFailure() }
            )
        }
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentModel>()).first?.savedComparisonJSON == nil)

        try ExperimentUIStore.updateSavedComparison(
            "comparison",
            for: experiment,
            in: context,
            now: now.addingTimeInterval(1)
        )
        #expect(experiment.savedComparisonJSON == "comparison")
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentModel>()).first?.savedComparisonJSON == "comparison")
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        try context.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Pending elsewhere")
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
    func multiTrackerEntriesCommitTogether() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let now = Date.now
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Atomic check-in",
            startedAt: now.addingTimeInterval(-60),
            plannedEndAt: now.addingTimeInterval(3_600)
        )
        let first = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Energy",
            type: .rating,
            cadence: .anytime,
            createdAt: experiment.startedAt
        )
        let second = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Notes",
            type: .note,
            cadence: .anytime,
            createdAt: experiment.startedAt
        )
        context.insert(experiment)
        context.insert(first)
        context.insert(second)
        try context.save()

        var stagedCount = 0
        try ExperimentUIStore.saveEntries(
            [
                .init(trackerID: first.id, value: .rating(4), observedAt: now),
                .init(trackerID: second.id, value: .note("Good session"), observedAt: now),
            ],
            for: experiment,
            in: context
        ) { transaction in
            stagedCount = try transaction.fetch(FetchDescriptor<ExperimentEntryModel>()).count
            let beforeCommit = ModelContext(container)
            #expect(try beforeCommit.fetch(FetchDescriptor<ExperimentEntryModel>()).isEmpty)
            try transaction.save()
        }

        let afterCommit = ModelContext(container)
        #expect(stagedCount == 2)
        #expect(try afterCommit.fetch(FetchDescriptor<ExperimentEntryModel>()).count == 2)
    }

    @Test
    func experimentManagementCommitsAsOneAction() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let now = Date.now
        let start = now.addingTimeInterval(-3_600)
        let originalEnd = now.addingTimeInterval(3_600)
        let revisedEnd = now.addingTimeInterval(7_200)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Original",
            startedAt: start,
            plannedEndAt: originalEnd
        )
        context.insert(experiment)
        try context.save()

        try ExperimentUIStore.updateManagement(
            .init(
                name: "Revised",
                protocolDescription: "One transaction",
                question: "Does it persist?",
                headlineMetricSelections: [],
                plannedEndAt: revisedEnd,
                reminderEnabled: true,
                reminderTime: now
            ),
            for: experiment,
            in: context,
            now: now,
            scheduleNotifications: false
        ) { transaction in
            let staged = try #require(
                transaction.fetch(FetchDescriptor<ExperimentModel>()).first
            )
            #expect(staged.name == "Revised")
            #expect(staged.plannedEndAt == revisedEnd)
            #expect(staged.reminderEnabled)

            let beforeCommit = ModelContext(container)
            let persistedBefore = try #require(
                beforeCommit.fetch(FetchDescriptor<ExperimentModel>()).first
            )
            #expect(persistedBefore.name == "Original")
            #expect(persistedBefore.plannedEndAt == originalEnd)
            #expect(!persistedBefore.reminderEnabled)
            try transaction.save()
        }

        let afterCommit = ModelContext(container)
        let persistedAfter = try #require(
            afterCommit.fetch(FetchDescriptor<ExperimentModel>()).first
        )
        #expect(persistedAfter.name == "Revised")
        #expect(persistedAfter.plannedEndAt == revisedEnd)
        #expect(persistedAfter.reminderEnabled)
    }

    @Test
    func failedManagementSavePreservesUnrelatedPendingEdit() throws {
        enum ExpectedFailure: Error { case write }

        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let now = Date.now
        let originalEnd = now.addingTimeInterval(3_600)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Original",
            startedAt: now.addingTimeInterval(-3_600),
            plannedEndAt: originalEnd
        )
        context.insert(experiment)
        try context.save()

        let unrelated = RoutineModel(userID: ForgeFitDemo.userID, name: "Pending routine")
        context.insert(unrelated)
        #expect(throws: ExpectedFailure.write) {
            try ExperimentUIStore.updateManagement(
                .init(
                    name: "Should not persist",
                    protocolDescription: "",
                    question: "",
                    headlineMetricSelections: [],
                    plannedEndAt: now.addingTimeInterval(7_200),
                    reminderEnabled: false,
                    reminderTime: now
                ),
                for: experiment,
                in: context,
                now: now,
                scheduleNotifications: false
            ) { _ in
                throw ExpectedFailure.write
            }
        }

        #expect(context.hasChanges)
        try context.save()
        let verification = ModelContext(container)
        let persistedExperiment = try #require(
            verification.fetch(FetchDescriptor<ExperimentModel>()).first
        )
        #expect(persistedExperiment.name == "Original")
        #expect(persistedExperiment.plannedEndAt == originalEnd)
        #expect(
            try verification.fetch(FetchDescriptor<RoutineModel>()).map(\.name)
                == ["Pending routine"]
        )
    }

    @Test
    func failedCheckInSaveDoesNotLeakEntriesOrErasePendingEdit() throws {
        enum ExpectedFailure: Error { case write }

        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let now = Date.now
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Atomic check-in",
            startedAt: now.addingTimeInterval(-60),
            plannedEndAt: now.addingTimeInterval(3_600)
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Energy",
            type: .rating,
            cadence: .anytime,
            createdAt: experiment.startedAt
        )
        context.insert(experiment)
        context.insert(tracker)
        try context.save()

        context.insert(RoutineModel(userID: ForgeFitDemo.userID, name: "Keep pending"))
        #expect(throws: ExpectedFailure.write) {
            try ExperimentUIStore.saveEntries(
                [.init(trackerID: tracker.id, value: .rating(5), observedAt: now)],
                for: experiment,
                in: context
            ) { _ in
                throw ExpectedFailure.write
            }
        }

        #expect(context.hasChanges)
        try context.save()
        let verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<ExperimentEntryModel>()).isEmpty)
        #expect(
            try verification.fetch(FetchDescriptor<RoutineModel>()).map(\.name)
                == ["Keep pending"]
        )
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
