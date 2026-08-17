import ForgeData
import Foundation
import SwiftData
import UserNotifications

/// Owns the date-driven experiment lifecycle. An experiment that has passed
/// its planned end is already over even if iOS never woke ForgeFit at that
/// exact instant; this service materializes that truth on launch/foreground.
@MainActor
enum ExperimentLifecycleService {
    static let activeState = "active"
    static let completedState = "completed"

    struct Reconciliation: Equatable {
        var completedIDs: [UUID] = []
        var duplicateActiveIDs: [UUID] = []
    }

    static func liveExperiments(in context: ModelContext) throws -> [ExperimentModel] {
        try context.fetch(
            FetchDescriptor<ExperimentModel>(
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
        )
        .filter { $0.deletedAt == nil && $0.stateRaw == activeState }
    }

    static func activeExperiment(
        in context: ModelContext,
        now: Date = .now
    ) throws -> ExperimentModel? {
        let live = try liveExperiments(in: context)
        return live.first { $0.plannedEndAt > now }
    }

    /// Completes expired rows at their scheduled end and reports any duplicate
    /// active rows without silently deleting them. UI start paths refuse to
    /// create the duplicates; this defense handles corrupt/legacy stores.
    @discardableResult
    static func reconcile(
        in context: ModelContext,
        now: Date = .now,
        persist: Bool = true
    ) throws -> Reconciliation {
        let live = try liveExperiments(in: context)
        var result = Reconciliation()
        var changed = false

        for experiment in live where experiment.plannedEndAt <= now {
            experiment.endedAt = experiment.plannedEndAt
            experiment.stateRaw = completedState
            experiment.updatedAt = now
            result.completedIDs.append(experiment.id)
            changed = true
        }

        let stillActive = live.filter { $0.plannedEndAt > now }
        if stillActive.count > 1 {
            result.duplicateActiveIDs = Array(stillActive.dropFirst().map(\.id))
        }

        if changed, persist {
            try context.save()
            for id in result.completedIDs {
                ExperimentNotificationScheduler.cancelAll(experimentID: id)
            }
        }
        return result
    }

    /// Launch and foreground maintenance must not commit edits that another
    /// screen is still holding in the shared context. Reconcile only durable
    /// inputs in a short-lived transaction and publish completion side effects
    /// after that transaction commits.
    @discardableResult
    static func reconcileIsolated(
        from sourceContext: ModelContext,
        now: Date = .now
    ) throws -> Reconciliation {
        let transaction = ModelContext(sourceContext.container)
        transaction.autosaveEnabled = false
        return try reconcile(in: transaction, now: now)
    }
}

/// Privacy-safe local notifications for one active experiment. Reminder
/// requests are consolidated by weekday, so custom trackers cannot exhaust
/// the system's finite pending-request budget.
@MainActor
enum ExperimentNotificationScheduler {
    /// Immutable values copied from SwiftData before any asynchronous work.
    /// Notification authorization and request submission can suspend; carrying
    /// managed models across those awaits would make a delete/reset destroy
    /// objects that an in-flight task still tries to read.
    struct ScheduleSnapshot: Sendable, Equatable {
        let experimentID: UUID
        let startedAt: Date
        let plannedEndAt: Date
        let timeZoneIdentifier: String
        let reminderEnabled: Bool
        let reminderTimeMinutes: Int?
        let dueWeekdays: Set<Int>

        init(
            experiment: ExperimentModel,
            trackers: [ExperimentTrackerModel]
        ) {
            experimentID = experiment.id
            startedAt = experiment.startedAt
            plannedEndAt = experiment.plannedEndAt
            timeZoneIdentifier = experiment.timeZoneIdentifier
            reminderEnabled = experiment.reminderEnabled
            reminderTimeMinutes = experiment.reminderTimeMinutes
            dueWeekdays = ExperimentNotificationScheduler.dueWeekdays(
                for: trackers
            )
        }

        var calendar: Calendar {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
            return calendar
        }
    }

    private static let prefix = "forgefit.experiment"
    /// One-off requests cannot outlive the experiment. A rolling four-week
    /// horizon leaves room under iOS's app-wide pending-request budget for
    /// rest timers and the user's ordinary ForgeFit reminders; foreground
    /// reconciliation replenishes the horizon.
    private static let reminderRequestLimit = 28
    /// Per-experiment task chaining prevents two reentrant notification-center
    /// updates from finishing out of order. The newest snapshot always runs
    /// after every older snapshot has either finished or noticed that it is
    /// stale.
    private static var scheduleTails: [UUID: Task<Bool, Never>] = [:]
    private static var latestScheduleToken: [UUID: UUID] = [:]

    private static func reminderID(experimentID: UUID, slot: Int) -> String {
        "\(prefix).\(experimentID.uuidString).reminder.\(slot)"
    }

    private static func endID(experimentID: UUID) -> String {
        "\(prefix).\(experimentID.uuidString).end"
    }

    @discardableResult
    static func schedule(
        _ snapshot: ScheduleSnapshot,
        now: Date = .now
    ) async -> Bool {
        let experimentID = snapshot.experimentID
        let previous = scheduleTails[experimentID]
        let token = UUID()
        latestScheduleToken[experimentID] = token
        let task = Task { @MainActor in
            _ = await previous?.value
            guard !Task.isCancelled,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
                  latestScheduleToken[experimentID] == token else {
                return false
            }
            return await performSchedule(snapshot, now: now, token: token)
        }
        scheduleTails[experimentID] = task
        let accepted = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        if latestScheduleToken[experimentID] == token {
            scheduleTails[experimentID] = nil
        }
        return accepted
    }

    private static func performSchedule(
        _ snapshot: ScheduleSnapshot,
        now: Date,
        token: UUID
    ) async -> Bool {
        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return false }
        removeAll(experimentID: snapshot.experimentID)

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              latestScheduleToken[snapshot.experimentID] == token else {
            removeAll(experimentID: snapshot.experimentID)
            return false
        }
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
            return false
        }

        let center = UNUserNotificationCenter.current()
        var accepted = false

        if snapshot.reminderEnabled {
            let minutes = min(max(snapshot.reminderTimeMinutes ?? (19 * 60), 0), 1_439)
            let dates = reminderDates(
                snapshot: snapshot,
                minutesAfterMidnight: minutes,
                now: now,
                limit: reminderRequestLimit
            )
            for (slot, date) in dates.enumerated() {
                guard !Task.isCancelled,
                      LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
                      latestScheduleToken[snapshot.experimentID] == token else {
                    removeAll(experimentID: snapshot.experimentID)
                    return false
                }
                let content = UNMutableNotificationContent()
                content.title = "Experiment check-in"
                content.body = "An experiment update is due."
                content.sound = .default

                do {
                    try await center.add(UNNotificationRequest(
                        identifier: reminderID(
                            experimentID: snapshot.experimentID,
                            slot: slot
                        ),
                        content: content,
                        trigger: UNTimeIntervalNotificationTrigger(
                            timeInterval: max(2, date.timeIntervalSince(now)),
                            repeats: false
                        )
                    ))
                    accepted = true
                } catch {
                    continue
                }
                guard !Task.isCancelled,
                      LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
                      latestScheduleToken[snapshot.experimentID] == token else {
                    removeAll(experimentID: snapshot.experimentID)
                    return false
                }
            }
        }

        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              latestScheduleToken[snapshot.experimentID] == token else {
            removeAll(experimentID: snapshot.experimentID)
            return false
        }
        let interval = snapshot.plannedEndAt.timeIntervalSince(now)
        if interval > 1 {
            let content = UNMutableNotificationContent()
            content.title = "Experiment complete"
            content.body = "Your results are ready in ForgeFit."
            content.sound = .default
            content.userInfo = [
                ExperimentNotificationRoute.userInfoURLKey:
                    ExperimentNotificationRoute.resultsURL(
                        experimentID: snapshot.experimentID
                    ).absoluteString,
            ]
            do {
                try await center.add(UNNotificationRequest(
                    identifier: endID(experimentID: snapshot.experimentID),
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                ))
                accepted = true
            } catch {
                // The date-driven lifecycle still completes without a request.
            }
            guard !Task.isCancelled,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
                  latestScheduleToken[snapshot.experimentID] == token else {
                removeAll(experimentID: snapshot.experimentID)
                return false
            }
        }
        return accepted
    }

    static func cancelReminders(experimentID: UUID) {
        let identifiers = reminderIdentifiers(experimentID: experimentID)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func cancelAll(experimentID: UUID) {
        latestScheduleToken[experimentID] = UUID()
        removeAll(experimentID: experimentID)
    }

    private static func removeAll(experimentID: UUID) {
        let identifiers = reminderIdentifiers(experimentID: experimentID)
            + [endID(experimentID: experimentID)]
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    static func cancelEveryExperimentNotification() {
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            let delivered = await center.deliveredNotifications()
                .map(\.request.identifier)
                .filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }

    static func reminderDates(
        experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        minutesAfterMidnight: Int,
        now: Date,
        limit: Int
    ) -> [Date] {
        reminderDates(
            snapshot: ScheduleSnapshot(
                experiment: experiment,
                trackers: trackers
            ),
            minutesAfterMidnight: minutesAfterMidnight,
            now: now,
            limit: limit
        )
    }

    private static func reminderDates(
        snapshot: ScheduleSnapshot,
        minutesAfterMidnight: Int,
        now: Date,
        limit: Int
    ) -> [Date] {
        guard limit > 0, snapshot.plannedEndAt > now else { return [] }
        guard !snapshot.dueWeekdays.isEmpty else { return [] }
        let calendar = snapshot.calendar
        var cursor = calendar.startOfDay(for: max(now, snapshot.startedAt))
        var dates: [Date] = []
        while cursor < snapshot.plannedEndAt, dates.count < limit {
            let weekday = calendar.component(.weekday, from: cursor)
            if snapshot.dueWeekdays.contains(weekday),
               let candidate = calendar.date(
                    bySettingHour: minutesAfterMidnight / 60,
                    minute: minutesAfterMidnight % 60,
                    second: 0,
                    of: cursor
               ),
               candidate >= snapshot.startedAt,
               candidate > now,
               candidate < snapshot.plannedEndAt {
                dates.append(candidate)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
        }
        return dates
    }

    private static func reminderIdentifiers(experimentID: UUID) -> [String] {
        // Include legacy weekday slots (1...7) while the new fixed slots cover
        // every current one-off request.
        let current = (0..<reminderRequestLimit).map {
            reminderID(experimentID: experimentID, slot: $0)
        }
        let legacy = (1...7).map {
            "\(prefix).\(experimentID.uuidString).reminder.\($0)"
        }
        return Array(Set(current + legacy))
    }

    private static func dueWeekdays(for trackers: [ExperimentTrackerModel]) -> Set<Int> {
        var weekdays = Set<Int>()
        for tracker in trackers where tracker.deletedAt == nil && tracker.archivedAt == nil {
            switch tracker.cadenceRaw {
            case "daily":
                weekdays.formUnion(1...7)
            case "selectedWeekdays":
                weekdays.formUnion(tracker.selectedWeekdays.filter { (1...7).contains($0) })
            default:
                break
            }
        }
        return weekdays
    }
}
