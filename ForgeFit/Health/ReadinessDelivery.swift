import BackgroundTasks
import ForgeData
import Foundation
import SwiftData
import UserNotifications
#if canImport(HealthKit)
import HealthKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Pure timing gate for the morning readiness alert. The notification is a
/// delivery surface for a complete score, never a reminder that Health data is
/// missing. Seven is the preferred time; 10:30 is the end of the useful
/// morning window.
nonisolated enum MorningReadinessDeliveryPolicy {
    static let notifyHour = 7
    static let cutoffHour = 10
    static let cutoffMinute = 30

    static func fireDate(
        now: Date,
        calendar: Calendar,
        hasCompleteSleep: Bool,
        hasDailyScore: Bool
    ) -> Date? {
        guard hasCompleteSleep, hasDailyScore,
              let preferred = calendar.date(
                bySettingHour: notifyHour,
                minute: 0,
                second: 0,
                of: now
              ),
              let cutoff = calendar.date(
                bySettingHour: cutoffHour,
                minute: cutoffMinute,
                second: 0,
                of: now
              )
        else { return nil }

        let candidate = max(now.addingTimeInterval(2), preferred)
        return candidate <= cutoff ? candidate : nil
    }
}

/// Delivers the morning readiness score before the user opens the app:
/// a pre-dawn `BGAppRefreshTask` plus HealthKit observer wake-ups (sleep /
/// HRV syncing from the watch overnight) re-query Health and recompute the
/// score. Every wake path is best-effort — iOS grants none deterministically —
/// so an alert is scheduled only when today's complete score is ready during
/// the useful morning window. No wake or incomplete data means no alert.
@MainActor
final class ReadinessDelivery {
    static let shared = ReadinessDelivery()

    /// Must match Info.plist's BGTaskSchedulerPermittedIdentifiers.
    nonisolated static let refreshTaskID = "org.xpetsllc.ForgeFit.readiness-refresh"
    private static let refreshHour = 5
    private static let refreshMinute = 45
    /// The fire date of the currently armed notification.
    private static let scheduledFireKey = "morningReadinessScheduledFire"
    /// Start-of-day of the last day a readiness was delivered (push fired,
    /// or the user opened the app and saw Home's ring).
    private static let lastFiredDayKey = "morningReadinessLastFiredDay"

    private var container: ModelContainer?
    private var observersStarted = false
    private var refreshTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var externalRefreshTasks: [UUID: Task<Void, Never>] = [:]
    private var isLiveWorkoutActive = false
    private var pendingRefreshAfterWorkout = false
    /// Keeps the observing HKHealthStore alive — observer queries stop if
    /// their store deallocates. AnyObject so the property compiles where
    /// HealthKit can't be imported.
    private var observerStore: AnyObject?

    /// Registration must happen before the app finishes launching —
    /// called from `ForgeFitApp.init`.
    nonisolated func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                ReadinessDelivery.shared.handleRefresh(refresh)
            }
        }
    }

    /// Wire the data source and start every background wake path. Safe to
    /// call again (foregrounds, Health connects) — observers start once,
    /// the refresh request and notification are simply renewed.
    func configure(container: ModelContainer) {
        self.container = container
        startHealthObservers()
        scheduleNextRefresh()
        refreshMorningNotification()
    }

    /// Health/readiness work is useful again after the session, but never
    /// while the logger owns the interaction budget. Suppressed wake-ups are
    /// collapsed into one delayed catch-up rather than replayed individually.
    func setLiveWorkoutActive(_ isActive: Bool) {
        guard isLiveWorkoutActive != isActive else { return }
        isLiveWorkoutActive = isActive
        if isActive {
            pendingRefreshAfterWorkout = true
            refreshTask?.cancel()
            refreshTask = nil
            resumeTask?.cancel()
            resumeTask = nil
            for task in externalRefreshTasks.values {
                task.cancel()
            }
            externalRefreshTasks.removeAll()
        } else if pendingRefreshAfterWorkout {
            schedulePostWorkoutCatchUp()
        }
    }

    // MARK: - BGAppRefresh (pre-dawn recompute)

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleNextRefresh()   // one-shot: always re-arm tomorrow's first
        guard !isLiveWorkoutActive else {
            pendingRefreshAfterWorkout = true
            task.setTaskCompleted(success: true)
            return
        }
        let id = UUID()
        let work = Task { @MainActor [weak self] in
            defer {
                task.setTaskCompleted(success: !Task.isCancelled)
                self?.externalRefreshTasks[id] = nil
            }
            guard let self else { return }
            guard !self.isLiveWorkoutActive else {
                self.pendingRefreshAfterWorkout = true
                return
            }
            await HealthMetricsStore.shared.refreshNow()
            guard !Task.isCancelled, !self.isLiveWorkoutActive else {
                pendingRefreshAfterWorkout = true
                return
            }
            let report = await refreshReadinessSurfacesNow()
            guard !Task.isCancelled else { return }
            await refreshMorningNotificationNow(precomputed: report)
        }
        externalRefreshTasks[id] = work
        task.expirationHandler = { work.cancel() }
    }

    private func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = nextOccurrence(hour: Self.refreshHour, minute: Self.refreshMinute)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - HealthKit background delivery (overnight sync wake-ups)

    /// Observer queries on sleep + HRV: when the watch syncs overnight data,
    /// iOS may wake the app briefly so the score and pending notification can
    /// refresh with the real morning numbers. This is the preferred path;
    /// BGAppRefresh is another best-effort opportunity.
    private func startHealthObservers() {
        #if canImport(HealthKit)
        guard !observersStarted, HKHealthStore.isHealthDataAvailable() else { return }
        observersStarted = true
        let store = HKHealthStore()
        observerStore = store
        var types: [HKSampleType] = []
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }
        if let hrv = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { types.append(hrv) }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else {
                    completion()
                    return
                }
                Task { @MainActor in
                    let id = UUID()
                    let work = Task { @MainActor in
                        defer {
                            completion()
                            ReadinessDelivery.shared.externalRefreshTasks[id] = nil
                        }
                        guard !ReadinessDelivery.shared.isLiveWorkoutActive else {
                            ReadinessDelivery.shared.pendingRefreshAfterWorkout = true
                            return
                        }
                        await HealthMetricsStore.shared.refreshNow()
                        guard !Task.isCancelled,
                              !ReadinessDelivery.shared.isLiveWorkoutActive else {
                            ReadinessDelivery.shared.pendingRefreshAfterWorkout = true
                            return
                        }
                        let report = await ReadinessDelivery.shared.refreshReadinessSurfacesNow()
                        guard !Task.isCancelled else { return }
                        await ReadinessDelivery.shared.refreshMorningNotificationNow(precomputed: report)
                    }
                    ReadinessDelivery.shared.externalRefreshTasks[id] = work
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
        #endif
    }

    // MARK: - Morning notification

    /// Called from every data-refresh path (pre-dawn BG task, HealthKit
    /// observer wakes, app foreground). A push is scheduled only when today's
    /// daily score includes complete sleep and is ready before the cutoff.
    func refreshMorningNotification() {
        guard !isLiveWorkoutActive else {
            pendingRefreshAfterWorkout = true
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshMorningNotificationNow()
            guard !Task.isCancelled else { return }
            refreshTask = nil
        }
    }

    private func refreshMorningNotificationNow(precomputed: RecoveryEngine.Report? = nil) async {
        guard !isLiveWorkoutActive else {
            pendingRefreshAfterWorkout = true
            return
        }
        guard NotificationScheduler.shared.morningReadinessEnabled else {
            cancelPendingMorningReadiness()
            return
        }
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let defaults = UserDefaults.standard

        // Opening the app in the morning IS the delivery — Home's ring shows
        // the live score. Cancel today's pending push instead of doubling up.
        // (5 AM floor so a post-midnight session doesn't eat the morning push.)
        #if canImport(UIKit)
        if UIApplication.shared.applicationState == .active,
           !deliveredToday(now: now, calendar: calendar),
           let fiveAM = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now),
           now >= fiveAM {
            defaults.set(today, forKey: Self.lastFiredDayKey)
            cancelPendingMorningReadiness()
            return
        }
        #endif

        if deliveredToday(now: now, calendar: calendar) {
            defaults.set(today, forKey: Self.lastFiredDayKey)
            cancelPendingMorningReadiness()
            return
        }

        // Background wakes get a few seconds total; reuse the report the
        // surface refresh just finished rather than scoring the day twice.
        let report: RecoveryEngine.Report?
        if let precomputed {
            report = precomputed
        } else {
            report = await computeReport()
        }
        guard !Task.isCancelled, !isLiveWorkoutActive else {
            pendingRefreshAfterWorkout = true
            return
        }
        let dailyScore = report?.recovery.daily.state.value

        // Sleep is attributed to the day it ended. Require today's trustworthy
        // duration and the ready sleep component so a score built from two
        // autonomic domains cannot masquerade as complete readiness.
        let sleepContributed = report?.recovery.daily.parts.contains {
            $0.name == "Sleep (last night)" && $0.state.value != nil
        } ?? false
        let hasCompleteSleep = sleepContributed && HealthMetricsStore.shared.metrics.contains {
            calendar.isDate($0.date, inSameDayAs: today)
                && $0.sleepTotalMinutes != nil
                && $0.sleepIsTrustworthy
                && $0.sleepOverrideStatus != .notTracked
        }

        guard
            let fireDate = MorningReadinessDeliveryPolicy.fireDate(
                now: now,
                calendar: calendar,
                hasCompleteSleep: hasCompleteSleep,
                hasDailyScore: dailyScore != nil
            ),
            let report,
            let dailyScore
        else {
            cancelPendingMorningReadiness()
            return
        }

        let score = Int((dailyScore * 100).rounded())
        defaults.set(fireDate, forKey: Self.scheduledFireKey)
        NotificationScheduler.shared.scheduleMorningReadiness(
            at: fireDate,
            title: "Readiness \(score) — \(report.action.title)",
            body: report.preWorkoutAdjustment
        )
    }

    /// A push counts as delivered today when it was seen in-app, or the
    /// armed notification's fire date has passed (it fired unattended).
    private func deliveredToday(now: Date, calendar: Calendar) -> Bool {
        let defaults = UserDefaults.standard
        if let day = defaults.object(forKey: Self.lastFiredDayKey) as? Date,
           calendar.isDate(day, inSameDayAs: now) {
            return true
        }
        if let fire = defaults.object(forKey: Self.scheduledFireKey) as? Date,
           calendar.isDate(fire, inSameDayAs: now), fire <= now {
            return true
        }
        return false
    }

    private func cancelPendingMorningReadiness() {
        UserDefaults.standard.removeObject(forKey: Self.scheduledFireKey)
        NotificationScheduler.shared.cancelMorningReadiness()
    }

    private func schedulePostWorkoutCatchUp() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, !isLiveWorkoutActive else { return }
            pendingRefreshAfterWorkout = false
            await HealthMetricsStore.shared.refreshIfStaleNow()
            guard !Task.isCancelled, !isLiveWorkoutActive else {
                pendingRefreshAfterWorkout = true
                return
            }
            // This is the replay of a wake-up that was suppressed mid-workout,
            // so it owes the surfaces the same refresh that wake-up would have
            // done — the workout that finished is itself a readiness input.
            let report = await refreshReadinessSurfacesNow()
            guard !Task.isCancelled else { return }
            await refreshMorningNotificationNow(precomputed: report)
            guard !Task.isCancelled else { return }
            resumeTask = nil
        }
    }

    private func computeAnalytics() async -> HomeAnalyticsResult? {
        guard let container else { return nil }
        let metricsStore = HealthMetricsStore.shared
        let input = HomeAnalyticsInput(
            healthMetrics: metricsStore.metrics,
            supplementalSignals: metricsStore.extraSignals,
            activityMetrics: metricsStore.activityMetrics,
            todayCheckinTags: ReadinessReportFactory.todayCheckinTags(in: container.mainContext),
            now: Date()
        )
        let worker = HomeAnalyticsWorker(modelContainer: container)
        return try? await worker.calculateCurrent(input)
    }

    private func computeReport() async -> RecoveryEngine.Report? {
        guard let result = await computeAnalytics() else { return nil }
        return result.recovery
    }

    // MARK: - Readiness surfaces

    /// Put a background-computed score on every readiness surface.
    ///
    /// Home is the only other producer, and it runs solely while its tab is
    /// on screen — so before this existed, a new day had no score anywhere
    /// (phone widget, Watch app, watch-face complication) until the user
    /// opened the app to Home. The wake-ups that already recompute for the
    /// morning notification had the finished report in hand and dropped it.
    ///
    /// Deliberately independent of the notification's own gating: the push is
    /// suppressed when the user has turned it off or has already seen today's
    /// readiness, neither of which says anything about whether the surfaces
    /// are current.
    @discardableResult
    private func refreshReadinessSurfacesNow() async -> RecoveryEngine.Report? {
        guard !isLiveWorkoutActive else {
            pendingRefreshAfterWorkout = true
            return nil
        }
        guard let result = await computeAnalytics() else { return nil }
        guard !Task.isCancelled, !isLiveWorkoutActive else {
            pendingRefreshAfterWorkout = true
            return nil
        }
        // The calendar's daily/trend/strain channels, but NOT the dashboard
        // cache: that field is documented as "Home exactly as last rendered",
        // and nothing has rendered here.
        RecoverySnapshotStore.shared.recordToday(
            daily: result.recovery.recovery.daily.state.value,
            trend: result.recovery.recovery.systemic.state.value,
            strain: result.strain.score,
            strainTarget: result.strain.targetRange
        )
        ReadinessSurfacePublisher.publishFresh(result.recovery)
        // A background wake may never have shown a scene, so the Watch link
        // can still be unconfigured; without this the publish silently no-ops
        // and the wrist keeps yesterday's number.
        if let container {
            WatchLink.shared.configureIfNeeded(container: container)
        }
        WatchLink.shared.activate()
        WatchLink.shared.publishState(policy: .immediate)
        return result.recovery
    }

    private func nextOccurrence(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let todays = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if todays > now { return todays }
        return calendar.date(byAdding: .day, value: 1, to: todays) ?? todays
    }
}
