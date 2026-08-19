import ForgeCore
import ForgeData
import Foundation
import SwiftData

enum ExperimentUIStoreError: LocalizedError, Equatable {
    case activeExperimentExists
    case activeWorkoutExists
    case experimentUnavailable
    case entryUnavailable
    case entryAlreadyExists
    case invalidName
    case invalidWindow
    case observationOutsideWindow
    case trackerNotDue
    case workoutRequired
    case workoutOutsideWindow
    case trackerUnavailable
    case invalidTrackerValue

    var errorDescription: String? {
        switch self {
        case .activeExperimentExists:
            "Finish the active experiment before starting another."
        case .activeWorkoutExists:
            "Finish or discard the active workout before starting an experiment."
        case .experimentUnavailable:
            "That experiment is no longer available."
        case .entryUnavailable:
            "That entry is no longer available."
        case .entryAlreadyExists:
            "An entry already exists for this tracker and date."
        case .invalidName:
            "Enter a name for this experiment."
        case .invalidWindow:
            "The experiment end must be after its start."
        case .observationOutsideWindow:
            "That entry is outside the experiment dates."
        case .trackerNotDue:
            "This tracker is not scheduled for that day."
        case .workoutRequired:
            "Choose the completed workout this entry belongs to."
        case .workoutOutsideWindow:
            "That workout is not part of this experiment."
        case .trackerUnavailable:
            "That tracker is no longer available for this experiment."
        case .invalidTrackerValue:
            "Enter a valid value for this tracker."
        }
    }
}

/// All SwiftData mutations initiated by Experiment views live here. Keeping
/// lifecycle calls centralized prevents a sheet or card from bypassing
/// one-active enforcement or leaving stale notifications behind.
@MainActor
enum ExperimentUIStore {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    struct ManagementUpdate {
        let name: String
        let protocolDescription: String
        let question: String
        let headlineMetricSelections: [ExperimentMetricSelection]
        let plannedEndAt: Date
        let reminderEnabled: Bool
        let reminderTime: Date
    }

    struct EntryUpdate {
        let trackerID: UUID
        let value: ExperimentEntryValue
        let observedAt: Date
        let workoutID: UUID?
        let editingEntryID: UUID?

        init(
            trackerID: UUID,
            value: ExperimentEntryValue,
            observedAt: Date,
            workoutID: UUID? = nil,
            editingEntryID: UUID? = nil
        ) {
            self.trackerID = trackerID
            self.value = value
            self.observedAt = observedAt
            self.workoutID = workoutID
            self.editingEntryID = editingEntryID
        }
    }

    struct TrackerMutationResult {
        let trackers: [ExperimentTrackerModel]
        let reminderEnabled: Bool
    }

    static func start(
        draft: ExperimentSetupDraft,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> ExperimentModel {
        let transaction = isolatedContext(from: context)
        let reconciliation = try ExperimentLifecycleService.reconcile(
            in: transaction,
            now: now,
            persist: false
        )
        guard try ExperimentLifecycleService.activeExperiment(in: transaction, now: now) == nil else {
            throw ExperimentUIStoreError.activeExperimentExists
        }
        let hasActiveWorkout = try transaction.fetch(FetchDescriptor<WorkoutModel>())
            .contains { $0.deletedAt == nil && $0.endedAt == nil }
        guard !hasActiveWorkout else {
            throw ExperimentUIStoreError.activeWorkoutExists
        }

        let end = draft.durationPreset.endDate(
            from: now,
            customDate: draft.customEndDate
        )
        guard end > now else { throw ExperimentUIStoreError.invalidWindow }

        let selections = ExperimentHeadlineMetricOption.all
            .filter { draft.headlineMetricIDs.contains($0.id) }
            .map(\.selection)
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: draft.trimmedName,
            protocolDescription: optionalText(draft.protocolDescription),
            question: optionalText(draft.question),
            startedAt: now,
            plannedEndAt: end,
            timeZoneIdentifier: TimeZone.current.identifier,
            state: .active,
            headlineMetricSelectionsJSON: encode(selections) ?? "[]",
            reminderEnabled: draft.reminderEnabled,
            reminderTimeMinutes: draft.reminderEnabled
                ? minutesAfterMidnight(draft.reminderTime)
                : nil
        )
        transaction.insert(experiment)

        let trackers = draft.trackers.enumerated().map { position, tracker in
            let model = ExperimentTrackerModel(
                userID: ForgeFitDemo.userID,
                experimentID: experiment.id,
                label: tracker.trimmedLabel,
                type: trackerType(tracker.kind),
                unit: optionalText(tracker.unit),
                scaleMinimumLabel: optionalText(tracker.lowLabel),
                scaleMaximumLabel: optionalText(tracker.highLabel),
                options: tracker.choices,
                cadence: trackerCadence(tracker.cadence),
                selectedWeekdays: tracker.weekdays.sorted(),
                position: position
            )
            transaction.insert(model)
            return model
        }

        try save(transaction)
        let experimentID = experiment.id
        guard let committed = try context.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        for id in reconciliation.completedIDs {
            ExperimentNotificationScheduler.cancelAll(experimentID: id)
        }

        let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
            experiment: experiment,
            trackers: trackers
        )
        Task {
            _ = await ExperimentNotificationScheduler.schedule(notificationSchedule)
        }
        return committed
    }

    static func stop(
        _ experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard experiment.deletedAt == nil, experiment.isActive else { return }
        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.deletedAt == nil,
        persistedExperiment.isActive else { return }

        let end = max(
            persistedExperiment.startedAt.addingTimeInterval(1),
            min(now, persistedExperiment.plannedEndAt)
        )
        persistedExperiment.endedAt = end
        persistedExperiment.state = .completed
        persistedExperiment.updatedAt = now
        try save(transaction)
        ExperimentNotificationScheduler.cancelAll(experimentID: experimentID)
    }

    /// Applies the whole Manage-sheet action inside one isolated context.
    /// A failed save can therefore neither roll back nor commit pending edits
    /// owned by another keep-resident tab.
    static func updateManagement(
        _ update: ManagementUpdate,
        for experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        scheduleNotifications: Bool = true,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let trimmedName = update.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ExperimentUIStoreError.invalidName }
        let encodedSelections = try JSONEncoder().encode(update.headlineMetricSelections)

        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.deletedAt == nil else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        let trackers = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }

        persistedExperiment.name = trimmedName
        persistedExperiment.protocolDescription = optionalText(update.protocolDescription)
        persistedExperiment.question = optionalText(update.question)
        persistedExperiment.headlineMetricSelectionsJSON = String(
            decoding: encodedSelections,
            as: UTF8.self
        )
        if persistedExperiment.isActive {
            guard update.plannedEndAt > now,
                  update.plannedEndAt > persistedExperiment.startedAt else {
                throw ExperimentUIStoreError.invalidWindow
            }
            persistedExperiment.plannedEndAt = update.plannedEndAt
            persistedExperiment.reminderEnabled = update.reminderEnabled
            persistedExperiment.reminderTimeMinutes = update.reminderEnabled
                ? minutesAfterMidnight(update.reminderTime)
                : nil
        }
        persistedExperiment.updatedAt = now
        try save(transaction)

        guard scheduleNotifications else { return }
        if persistedExperiment.isActive {
            let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
                experiment: persistedExperiment,
                trackers: trackers
            )
            Task {
                _ = await ExperimentNotificationScheduler.schedule(notificationSchedule)
            }
        } else {
            ExperimentNotificationScheduler.cancelAll(experimentID: experimentID)
        }
    }

    /// Adds or edits one tracker without sharing a save boundary with the
    /// environment context. Trackers that already own entries are versioned;
    /// otherwise the existing row is updated in place, matching the prior UI
    /// behavior while making a failed retry duplicate-safe.
    static func upsertTracker(
        _ draft: ExperimentSetupTrackerDraft,
        replacing trackerID: UUID?,
        for experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        scheduleNotifications: Bool = true,
        save: SaveOperation = { try $0.save() }
    ) throws -> TrackerMutationResult {
        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.isActive else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        var trackers = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }
        let entries = try transaction.fetch(FetchDescriptor<ExperimentEntryModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }

        if let trackerID {
            guard let tracker = trackers.first(where: { $0.id == trackerID }) else {
                throw ExperimentUIStoreError.trackerUnavailable
            }
            guard !trackerDefinitionMatches(draft, tracker: tracker) else {
                return try trackerMutationResult(
                    experiment: persistedExperiment,
                    experimentID: experimentID,
                    in: context
                )
            }
            if entries.contains(where: { $0.trackerID == trackerID }) {
                tracker.archivedAt = now
                tracker.updatedAt = now
                let replacement = makeTracker(
                    from: draft,
                    experiment: persistedExperiment,
                    position: tracker.position,
                    definitionVersion: tracker.definitionVersion + 1,
                    now: now
                )
                transaction.insert(replacement)
                trackers.append(replacement)
            } else {
                apply(draft, to: tracker)
                tracker.definitionVersion += 1
                tracker.updatedAt = now
            }
        } else {
            let nextPosition = (trackers
                .filter { $0.archivedAt == nil }
                .map(\.position)
                .max() ?? -1) + 1
            let tracker = makeTracker(
                from: draft,
                experiment: persistedExperiment,
                position: nextPosition,
                definitionVersion: 1,
                now: now
            )
            transaction.insert(tracker)
            trackers.append(tracker)
        }

        disableUnavailableReminder(
            for: persistedExperiment,
            trackers: trackers,
            now: now
        )
        try save(transaction)
        if scheduleNotifications {
            scheduleNotificationsAfterCommit(
                for: persistedExperiment,
                trackers: trackers
            )
        }
        return try trackerMutationResult(
            experiment: persistedExperiment,
            experimentID: experimentID,
            in: context
        )
    }

    static func archiveTracker(
        _ tracker: ExperimentTrackerModel,
        for experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        scheduleNotifications: Bool = true,
        save: SaveOperation = { try $0.save() }
    ) throws -> TrackerMutationResult {
        let experimentID = experiment.id
        let trackerID = tracker.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.isActive else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        let trackers = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }
        guard let persistedTracker = trackers.first(where: { $0.id == trackerID }),
              persistedTracker.archivedAt == nil else {
            throw ExperimentUIStoreError.trackerUnavailable
        }

        persistedTracker.archivedAt = now
        persistedTracker.updatedAt = now
        disableUnavailableReminder(
            for: persistedExperiment,
            trackers: trackers,
            now: now
        )
        try save(transaction)
        if scheduleNotifications {
            scheduleNotificationsAfterCommit(
                for: persistedExperiment,
                trackers: trackers
            )
        }
        return try trackerMutationResult(
            experiment: persistedExperiment,
            experimentID: experimentID,
            in: context
        )
    }

    static func moveTracker(
        _ tracker: ExperimentTrackerModel,
        offset: Int,
        for experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> TrackerMutationResult {
        let experimentID = experiment.id
        let trackerID = tracker.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.isActive else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        var ordered = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter {
                $0.experimentID == experimentID
                    && $0.deletedAt == nil
                    && $0.archivedAt == nil
            }
            .sorted {
                if $0.position == $1.position {
                    return $0.createdAt < $1.createdAt
                }
                return $0.position < $1.position
            }
        guard let source = ordered.firstIndex(where: { $0.id == trackerID }) else {
            throw ExperimentUIStoreError.trackerUnavailable
        }
        let destination = source + offset
        guard ordered.indices.contains(destination) else {
            return try trackerMutationResult(
                experiment: persistedExperiment,
                experimentID: experimentID,
                in: context
            )
        }
        ordered.swapAt(source, destination)
        for (position, item) in ordered.enumerated() {
            item.position = position
            item.updatedAt = now
        }
        try save(transaction)
        return try trackerMutationResult(
            experiment: persistedExperiment,
            experimentID: experimentID,
            in: context
        )
    }

    /// Restoring creates a new definition lifetime instead of reopening the
    /// archived row. The old row remains the owner of its historical entries,
    /// and the inactive gap never becomes expected coverage or a valid
    /// backfill window.
    @discardableResult
    static func restoreTrackerVersion(
        _ tracker: ExperimentTrackerModel,
        for experiment: ExperimentModel,
        position: Int,
        in context: ModelContext,
        now: Date = .now,
        scheduleNotifications: Bool = true,
        save: SaveOperation = { try $0.save() }
    ) throws -> ExperimentTrackerModel {
        let experimentID = experiment.id
        let trackerID = tracker.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.isActive else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        var trackers = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }
        guard let persistedTracker = trackers.first(where: { $0.id == trackerID }),
              persistedTracker.archivedAt != nil else {
            throw ExperimentUIStoreError.trackerUnavailable
        }

        let replacement = ExperimentTrackerModel(
            userID: persistedTracker.userID,
            experimentID: persistedTracker.experimentID,
            label: persistedTracker.label,
            type: persistedTracker.type,
            unit: persistedTracker.unit,
            scaleMinimumLabel: persistedTracker.scaleMinimumLabel,
            scaleMaximumLabel: persistedTracker.scaleMaximumLabel,
            options: persistedTracker.options,
            cadence: persistedTracker.cadence,
            selectedWeekdays: persistedTracker.selectedWeekdays,
            position: position,
            definitionVersion: persistedTracker.definitionVersion + 1,
            createdAt: now,
            updatedAt: now
        )
        transaction.insert(replacement)
        trackers.append(replacement)
        try save(transaction)
        if scheduleNotifications {
            scheduleNotificationsAfterCommit(
                for: persistedExperiment,
                trackers: trackers
            )
        }
        let replacementID = replacement.id
        guard let resolved = try context.fetch(
            FetchDescriptor<ExperimentTrackerModel>(predicate: #Predicate { $0.id == replacementID })
        ).first else { throw ExperimentUIStoreError.trackerUnavailable }
        return resolved
    }

    static func discard(
        _ experiment: ExperimentModel,
        trackers _: [ExperimentTrackerModel],
        entries _: [ExperimentEntryModel],
        in context: ModelContext
    ) throws {
        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        // Experiment text may contain sensitive custom information. These
        // models are local-only and have no sync tombstone requirement, so a
        // user-facing Delete performs a real model deletion rather than
        // retaining the content indefinitely behind `deletedAt`.
        let entries = try transaction.fetch(FetchDescriptor<ExperimentEntryModel>())
            .filter { $0.experimentID == experimentID }
        let trackers = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID }
        for entry in entries {
            transaction.delete(entry)
        }
        for tracker in trackers {
            transaction.delete(tracker)
        }
        if let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first {
            transaction.delete(persistedExperiment)
        }
        try transaction.save()
        ExperimentNotificationScheduler.cancelAll(experimentID: experimentID)
    }

    /// Daily and per-workout schedules update the existing observation rather
    /// than manufacturing duplicates. Anytime trackers always append.
    @discardableResult
    static func saveEntry(
        value: ExperimentEntryValue,
        tracker: ExperimentTrackerModel,
        experiment: ExperimentModel,
        entries: [ExperimentEntryModel],
        observedAt: Date,
        workoutID: UUID? = nil,
        in context: ModelContext,
        calendar baseCalendar: Calendar = .current,
        existingEntryID: UUID? = nil,
        saveChanges: Bool = true
    ) throws -> ExperimentEntryModel {
        guard tracker.experimentID == experiment.id, tracker.deletedAt == nil else {
            throw ExperimentUIStoreError.trackerUnavailable
        }
        guard isValid(value, for: tracker) else {
            throw ExperimentUIStoreError.invalidTrackerValue
        }
        var resolvedObservedAt = observedAt
        if tracker.cadence == .perWorkout {
            guard let workoutID else {
                throw ExperimentUIStoreError.workoutRequired
            }
            guard let workout = try context.fetch(FetchDescriptor<WorkoutModel>())
                .first(where: {
                    $0.id == workoutID
                        && $0.deletedAt == nil
                        && $0.endedAt != nil
                }),
                  workout.startedAt >= experiment.startedAt,
                  workout.startedAt < (experiment.endedAt ?? experiment.plannedEndAt) else {
                throw ExperimentUIStoreError.workoutOutsideWindow
            }
            // Workout membership is anchored to its start. Store that same
            // instant so logging, results, and post-workout prompts cannot
            // disagree at an experiment end boundary.
            resolvedObservedAt = workout.startedAt
        }
        guard experiment.contains(
            resolvedObservedAt,
            asOf: max(.now, experiment.endedAt ?? .now)
        ) else {
            throw ExperimentUIStoreError.observationOutsideWindow
        }
        let trackerStart = max(experiment.startedAt, tracker.createdAt)
        let experimentEnd = experiment.endedAt ?? experiment.plannedEndAt
        let trackerEnd = min(experimentEnd, tracker.archivedAt ?? experimentEnd)
        guard resolvedObservedAt >= trackerStart,
              resolvedObservedAt < trackerEnd else {
            throw ExperimentUIStoreError.trackerUnavailable
        }

        var calendar = baseCalendar
        calendar.timeZone = TimeZone(identifier: experiment.timeZoneIdentifier) ?? .current
        if tracker.cadence == .selectedWeekdays {
            let weekday = calendar.component(.weekday, from: resolvedObservedAt)
            guard tracker.selectedWeekdays.contains(weekday) else {
                throw ExperimentUIStoreError.trackerNotDue
            }
        }

        let liveEntries = entries.filter {
            $0.deletedAt == nil
                && $0.experimentID == experiment.id
                && $0.trackerID == tracker.id
        }
        let existing: ExperimentEntryModel?
        if let existingEntryID {
            guard let editingEntry = liveEntries.first(where: { $0.id == existingEntryID }) else {
                throw ExperimentUIStoreError.entryUnavailable
            }
            let conflicts: Bool = switch tracker.cadence {
            case .daily, .selectedWeekdays:
                liveEntries.contains {
                    $0.id != existingEntryID
                        && calendar.isDate($0.observedAt, inSameDayAs: resolvedObservedAt)
                }
            case .perWorkout:
                workoutID.map { id in
                    liveEntries.contains { $0.id != existingEntryID && $0.workoutID == id }
                } ?? false
            case .anytime:
                false
            }
            guard !conflicts else { throw ExperimentUIStoreError.entryAlreadyExists }
            existing = editingEntry
        } else {
            existing = switch tracker.cadence {
            case .daily, .selectedWeekdays:
                liveEntries.first {
                    calendar.isDate($0.observedAt, inSameDayAs: resolvedObservedAt)
                }
            case .perWorkout:
                workoutID.flatMap { id in liveEntries.first { $0.workoutID == id } }
            case .anytime:
                nil
            }
        }

        if let existing {
            let original = EntrySnapshot(existing)
            existing.value = value
            existing.observedAt = resolvedObservedAt
            existing.workoutID = workoutID
            existing.definitionSnapshotJSON = definitionSnapshot(for: tracker)
            existing.updatedAt = .now
            guard saveChanges else { return existing }
            do {
                try context.save()
            } catch {
                original.restore(existing)
                throw error
            }
            return existing
        }

        let entry = ExperimentEntryModel(
            userID: experiment.userID,
            experimentID: experiment.id,
            trackerID: tracker.id,
            workoutID: workoutID,
            observedAt: resolvedObservedAt,
            value: value,
            definitionSnapshotJSON: definitionSnapshot(for: tracker)
        )
        context.insert(entry)
        guard saveChanges else { return entry }
        do {
            try context.save()
            return entry
        } catch {
            context.delete(entry)
            throw error
        }
    }

    /// Saves every value from one check-in sheet as one isolated transaction.
    /// Retrying after a failure cannot duplicate an earlier anytime entry.
    static func saveEntries(
        _ updates: [EntryUpdate],
        for experiment: ExperimentModel,
        in context: ModelContext,
        calendar: Calendar = .current,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard !updates.isEmpty else { return }
        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.deletedAt == nil else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        let trackers = try transaction.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }
        var entries = try transaction.fetch(FetchDescriptor<ExperimentEntryModel>())
            .filter { $0.experimentID == experimentID }

        for update in updates {
            guard let tracker = trackers.first(where: { $0.id == update.trackerID }) else {
                throw ExperimentUIStoreError.trackerUnavailable
            }
            let entry = try saveEntry(
                value: update.value,
                tracker: tracker,
                experiment: persistedExperiment,
                entries: entries,
                observedAt: update.observedAt,
                workoutID: update.workoutID,
                in: transaction,
                calendar: calendar,
                existingEntryID: update.editingEntryID,
                saveChanges: false
            )
            if !entries.contains(where: { $0.id == entry.id }) {
                entries.append(entry)
            }
        }
        try save(transaction)
    }

    static func deleteEntry(
        _ entry: ExperimentEntryModel,
        in context: ModelContext,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let entryID = entry.id
        let transaction = isolatedContext(from: context)
        guard let persistedEntry = try transaction.fetch(
            FetchDescriptor<ExperimentEntryModel>(predicate: #Predicate { $0.id == entryID })
        ).first else { return }
        transaction.delete(persistedEntry)
        try save(transaction)
    }

    static func markResultsViewed(
        _ experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.deletedAt == nil else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        guard persistedExperiment.resultsViewedAt == nil else { return }
        persistedExperiment.resultsViewedAt = now
        persistedExperiment.updatedAt = now
        try save(transaction)
        _ = try context.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first
    }

    static func updateSavedComparison(
        _ json: String,
        for experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        let experimentID = experiment.id
        let transaction = isolatedContext(from: context)
        guard let persistedExperiment = try transaction.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first,
        persistedExperiment.deletedAt == nil else {
            throw ExperimentUIStoreError.experimentUnavailable
        }
        guard persistedExperiment.savedComparisonJSON != json else { return }
        persistedExperiment.savedComparisonJSON = json
        persistedExperiment.updatedAt = now
        try save(transaction)
        _ = try context.fetch(
            FetchDescriptor<ExperimentModel>(predicate: #Predicate { $0.id == experimentID })
        ).first
    }

    static func headlineSelections(for experiment: ExperimentModel) -> [ExperimentMetricSelection] {
        guard let data = experiment.headlineMetricSelectionsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ExperimentMetricSelection].self, from: data)) ?? []
    }

    static func trackerType(_ kind: ExperimentTrackerUIKind) -> ExperimentTrackerType {
        ExperimentTrackerType(rawValue: kind.rawValue) ?? .note
    }

    static func trackerCadence(_ cadence: ExperimentTrackerUICadence) -> ExperimentTrackerCadence {
        ExperimentTrackerCadence(rawValue: cadence.rawValue) ?? .anytime
    }

    private struct TrackerDefinitionSnapshot: Codable {
        let version: Int
        let label: String
        let type: ExperimentTrackerType
        let unit: String?
        let scaleMinimumLabel: String?
        let scaleMaximumLabel: String?
        let options: [String]
    }

    private struct EntrySnapshot {
        let valueTypeRaw: String
        let numericValue: Double?
        let booleanValue: Bool?
        let ratingValue: Int?
        let choiceValue: String?
        let textValue: String?
        let observedAt: Date
        let workoutID: UUID?
        let definitionSnapshotJSON: String
        let updatedAt: Date
        let deletedAt: Date?

        init(_ entry: ExperimentEntryModel) {
            valueTypeRaw = entry.valueTypeRaw
            numericValue = entry.numericValue
            booleanValue = entry.booleanValue
            ratingValue = entry.ratingValue
            choiceValue = entry.choiceValue
            textValue = entry.textValue
            observedAt = entry.observedAt
            workoutID = entry.workoutID
            definitionSnapshotJSON = entry.definitionSnapshotJSON
            updatedAt = entry.updatedAt
            deletedAt = entry.deletedAt
        }

        func restore(_ entry: ExperimentEntryModel) {
            entry.valueTypeRaw = valueTypeRaw
            entry.numericValue = numericValue
            entry.booleanValue = booleanValue
            entry.ratingValue = ratingValue
            entry.choiceValue = choiceValue
            entry.textValue = textValue
            entry.observedAt = observedAt
            entry.workoutID = workoutID
            entry.definitionSnapshotJSON = definitionSnapshotJSON
            entry.updatedAt = updatedAt
            entry.deletedAt = deletedAt
        }
    }

    private static func trackerMutationResult(
        experiment: ExperimentModel,
        experimentID: UUID,
        in sourceContext: ModelContext
    ) throws -> TrackerMutationResult {
        let trackers = try sourceContext.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID && $0.deletedAt == nil }
        return TrackerMutationResult(
            trackers: trackers,
            reminderEnabled: experiment.reminderEnabled
        )
    }

    private static func makeTracker(
        from draft: ExperimentSetupTrackerDraft,
        experiment: ExperimentModel,
        position: Int,
        definitionVersion: Int,
        now: Date
    ) -> ExperimentTrackerModel {
        ExperimentTrackerModel(
            userID: experiment.userID,
            experimentID: experiment.id,
            label: draft.trimmedLabel,
            type: trackerType(draft.kind),
            unit: optionalText(draft.unit),
            scaleMinimumLabel: optionalText(draft.lowLabel),
            scaleMaximumLabel: optionalText(draft.highLabel),
            options: normalizedChoices(draft.choices),
            cadence: trackerCadence(draft.cadence),
            selectedWeekdays: draft.weekdays.sorted(),
            position: position,
            definitionVersion: definitionVersion,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func apply(
        _ draft: ExperimentSetupTrackerDraft,
        to tracker: ExperimentTrackerModel
    ) {
        tracker.label = draft.trimmedLabel
        tracker.type = trackerType(draft.kind)
        tracker.unit = optionalText(draft.unit)
        tracker.scaleMinimumLabel = optionalText(draft.lowLabel)
        tracker.scaleMaximumLabel = optionalText(draft.highLabel)
        tracker.options = normalizedChoices(draft.choices)
        tracker.cadence = trackerCadence(draft.cadence)
        tracker.selectedWeekdays = draft.weekdays.sorted()
    }

    private static func trackerDefinitionMatches(
        _ draft: ExperimentSetupTrackerDraft,
        tracker: ExperimentTrackerModel
    ) -> Bool {
        tracker.label == draft.trimmedLabel
            && tracker.type == trackerType(draft.kind)
            && tracker.unit == optionalText(draft.unit)
            && tracker.scaleMinimumLabel == optionalText(draft.lowLabel)
            && tracker.scaleMaximumLabel == optionalText(draft.highLabel)
            && tracker.options == normalizedChoices(draft.choices)
            && tracker.cadence == trackerCadence(draft.cadence)
            && tracker.selectedWeekdays == draft.weekdays.sorted()
    }

    private static func normalizedChoices(_ choices: [String]) -> [String] {
        var seen = Set<String>()
        return choices.compactMap { choice in
            let trimmed = choice.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    private static func disableUnavailableReminder(
        for experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        now: Date
    ) {
        let hasScheduledTracker = trackers.contains {
            $0.deletedAt == nil
                && $0.archivedAt == nil
                && ($0.cadence == .daily || $0.cadence == .selectedWeekdays)
        }
        guard !hasScheduledTracker else { return }
        experiment.reminderEnabled = false
        experiment.reminderTimeMinutes = nil
        experiment.updatedAt = now
    }

    private static func scheduleNotificationsAfterCommit(
        for experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel]
    ) {
        guard experiment.isActive else { return }
        let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
            experiment: experiment,
            trackers: trackers
        )
        Task {
            _ = await ExperimentNotificationScheduler.schedule(notificationSchedule)
        }
    }

    private static func definitionSnapshot(for tracker: ExperimentTrackerModel) -> String {
        encode(TrackerDefinitionSnapshot(
            version: tracker.definitionVersion,
            label: tracker.label,
            type: tracker.type,
            unit: tracker.unit,
            scaleMinimumLabel: tracker.scaleMinimumLabel,
            scaleMaximumLabel: tracker.scaleMaximumLabel,
            options: tracker.options
        )) ?? "{}"
    }

    private static func isValid(
        _ value: ExperimentEntryValue,
        for tracker: ExperimentTrackerModel
    ) -> Bool {
        switch (tracker.type, value) {
        case let (.number, .number(number)):
            number.isFinite
        case (.boolean, .boolean):
            true
        case let (.rating, .rating(rating)):
            (1...5).contains(rating)
        case let (.choice, .choice(choice)):
            tracker.options.contains(choice)
        case let (.note, .note(note)):
            !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            false
        }
    }

    private static func minutesAfterMidnight(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return min(max((components.hour ?? 0) * 60 + (components.minute ?? 0), 0), 1_439)
    }

    private static func optionalText(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func isolatedContext(from context: ModelContext) -> ModelContext {
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        return transaction
    }
}
