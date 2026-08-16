import ForgeCore
import ForgeData
import Foundation
import SwiftData

enum ExperimentUIStoreError: LocalizedError, Equatable {
    case activeExperimentExists
    case activeWorkoutExists
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
    static func start(
        draft: ExperimentSetupDraft,
        in context: ModelContext,
        now: Date = .now
    ) throws -> ExperimentModel {
        try ExperimentLifecycleService.reconcile(in: context, now: now)
        guard try ExperimentLifecycleService.activeExperiment(in: context, now: now) == nil else {
            throw ExperimentUIStoreError.activeExperimentExists
        }
        let hasActiveWorkout = try context.fetch(FetchDescriptor<WorkoutModel>())
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
        context.insert(experiment)

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
            context.insert(model)
            return model
        }

        do {
            try context.save()
        } catch {
            context.delete(experiment)
            trackers.forEach(context.delete)
            throw error
        }

        let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
            experiment: experiment,
            trackers: trackers
        )
        Task {
            _ = await ExperimentNotificationScheduler.schedule(notificationSchedule)
        }
        return experiment
    }

    static func stop(
        _ experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now
    ) throws {
        guard experiment.deletedAt == nil, experiment.isActive else { return }
        let end = max(experiment.startedAt.addingTimeInterval(1), min(now, experiment.plannedEndAt))
        experiment.endedAt = end
        experiment.state = .completed
        experiment.updatedAt = now
        try context.save()
        ExperimentNotificationScheduler.cancelAll(experimentID: experiment.id)
    }

    static func updatePlannedEnd(
        _ end: Date,
        for experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        in context: ModelContext,
        scheduleNotifications: Bool = true,
        now: Date = .now
    ) throws {
        guard end > experiment.startedAt else { throw ExperimentUIStoreError.invalidWindow }
        experiment.plannedEndAt = end
        experiment.updatedAt = now
        if end <= now {
            experiment.endedAt = end
            experiment.state = .completed
        }
        try context.save()

        if experiment.isActive, scheduleNotifications {
            let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
                experiment: experiment,
                trackers: trackers
            )
            Task {
                _ = await ExperimentNotificationScheduler.schedule(
                    notificationSchedule
                )
            }
        } else if !experiment.isActive {
            ExperimentNotificationScheduler.cancelAll(experimentID: experiment.id)
        }
    }

    static func updateReminder(
        enabled: Bool,
        time: Date,
        for experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        in context: ModelContext,
        scheduleNotifications: Bool = true
    ) throws {
        experiment.reminderEnabled = enabled
        experiment.reminderTimeMinutes = enabled ? minutesAfterMidnight(time) : nil
        experiment.updatedAt = .now
        try context.save()
        if scheduleNotifications {
            let notificationSchedule = ExperimentNotificationScheduler.ScheduleSnapshot(
                experiment: experiment,
                trackers: trackers
            )
            Task {
                _ = await ExperimentNotificationScheduler.schedule(notificationSchedule)
            }
        }
    }

    static func updateMetadata(
        name: String,
        protocolDescription: String,
        question: String,
        for experiment: ExperimentModel,
        in context: ModelContext
    ) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        experiment.name = trimmedName
        experiment.protocolDescription = optionalText(protocolDescription)
        experiment.question = optionalText(question)
        experiment.updatedAt = .now
        try context.save()
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
        now: Date = .now
    ) throws -> ExperimentTrackerModel {
        guard experiment.isActive,
              tracker.experimentID == experiment.id,
              tracker.deletedAt == nil,
              tracker.archivedAt != nil else {
            throw ExperimentUIStoreError.trackerUnavailable
        }

        let replacement = ExperimentTrackerModel(
            userID: tracker.userID,
            experimentID: tracker.experimentID,
            label: tracker.label,
            type: tracker.type,
            unit: tracker.unit,
            scaleMinimumLabel: tracker.scaleMinimumLabel,
            scaleMaximumLabel: tracker.scaleMaximumLabel,
            options: tracker.options,
            cadence: tracker.cadence,
            selectedWeekdays: tracker.selectedWeekdays,
            position: position,
            definitionVersion: tracker.definitionVersion + 1,
            createdAt: now,
            updatedAt: now
        )
        context.insert(replacement)
        do {
            try context.save()
            return replacement
        } catch {
            context.delete(replacement)
            throw error
        }
    }

    static func discard(
        _ experiment: ExperimentModel,
        trackers _: [ExperimentTrackerModel],
        entries _: [ExperimentEntryModel],
        in context: ModelContext
    ) throws {
        let experimentID = experiment.id
        // Experiment text may contain sensitive custom information. These
        // models are local-only and have no sync tombstone requirement, so a
        // user-facing Delete performs a real model deletion rather than
        // retaining the content indefinitely behind `deletedAt`.
        let entries = try context.fetch(FetchDescriptor<ExperimentEntryModel>())
            .filter { $0.experimentID == experimentID }
        let trackers = try context.fetch(FetchDescriptor<ExperimentTrackerModel>())
            .filter { $0.experimentID == experimentID }
        for entry in entries {
            context.delete(entry)
        }
        for tracker in trackers {
            context.delete(tracker)
        }
        context.delete(experiment)
        try context.save()
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
        calendar baseCalendar: Calendar = .current
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
        let existing: ExperimentEntryModel? = switch tracker.cadence {
        case .daily, .selectedWeekdays:
            liveEntries.first {
                calendar.isDate($0.observedAt, inSameDayAs: resolvedObservedAt)
            }
        case .perWorkout:
            workoutID.flatMap { id in liveEntries.first { $0.workoutID == id } }
        case .anytime:
            nil
        }

        if let existing {
            existing.value = value
            existing.observedAt = resolvedObservedAt
            existing.workoutID = workoutID
            existing.definitionSnapshotJSON = definitionSnapshot(for: tracker)
            existing.updatedAt = .now
            try context.save()
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
        do {
            try context.save()
            return entry
        } catch {
            context.delete(entry)
            throw error
        }
    }

    static func deleteEntry(
        _ entry: ExperimentEntryModel,
        in context: ModelContext
    ) throws {
        context.delete(entry)
        try context.save()
    }

    static func markResultsViewed(
        _ experiment: ExperimentModel,
        in context: ModelContext,
        now: Date = .now
    ) {
        guard experiment.resultsViewedAt == nil else { return }
        experiment.resultsViewedAt = now
        experiment.updatedAt = now
        context.saveUserChanges()
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
}
