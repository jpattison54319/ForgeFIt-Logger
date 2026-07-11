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

/// Delivers the morning readiness score before the user opens the app:
/// a pre-dawn `BGAppRefreshTask` plus HealthKit observer wake-ups (sleep /
/// HRV syncing from the watch overnight) re-query Health, recompute the
/// score, and keep a 7 AM local notification's content fresh. Every wake
/// path is best-effort — iOS grants none of them deterministically — so the
/// notification is scheduled with the latest known score and simply
/// re-scheduled with fresher numbers each time a wake actually lands.
@MainActor
final class ReadinessDelivery {
    static let shared = ReadinessDelivery()

    /// Must match Info.plist's BGTaskSchedulerPermittedIdentifiers.
    nonisolated static let refreshTaskID = "org.xpetsllc.ForgeFit.readiness-refresh"
    /// Delivery is gated on last night's data EXISTING, not on the clock:
    /// the watch writes sleep only after the user wakes and syncs, so a
    /// fixed-time push while they're still asleep would carry a score
    /// computed without last night. Synced before 7 → fire at 7. Synced
    /// after 7 → the observer wake fires it immediately (which, because the
    /// sync follows wake-up, means right after they're up). Nothing synced
    /// by 10:30 → push with honest "sleep hasn't synced yet" copy.
    private static let notifyHour = 7
    private static let fallbackHour = 10
    private static let fallbackMinute = 30
    private static let refreshHour = 5
    private static let refreshMinute = 45
    /// The fire date of the currently armed notification.
    private static let scheduledFireKey = "morningReadinessScheduledFire"
    /// Start-of-day of the last day a readiness was delivered (push fired,
    /// or the user opened the app and saw Home's ring).
    private static let lastFiredDayKey = "morningReadinessLastFiredDay"

    private var container: ModelContainer?
    private var observersStarted = false
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

    // MARK: - BGAppRefresh (pre-dawn recompute)

    private func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleNextRefresh()   // one-shot: always re-arm tomorrow's first
        let work = Task { @MainActor in
            await HealthMetricsStore.shared.refreshNow()
            refreshMorningNotification()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = nextOccurrence(hour: Self.refreshHour, minute: Self.refreshMinute)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - HealthKit background delivery (overnight sync wake-ups)

    /// Observer queries on sleep + HRV: when the watch syncs overnight data,
    /// iOS wakes the app briefly and the score/notification refresh with the
    /// real morning numbers — this is the reliable path; BGAppRefresh is the
    /// fallback.
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
                    await HealthMetricsStore.shared.refreshNow()
                    ReadinessDelivery.shared.refreshMorningNotification()
                    completion()
                }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
        #endif
    }

    // MARK: - Morning notification

    /// Called from every data-refresh path (pre-dawn BG task, HealthKit
    /// observer wakes, app foreground). Decides whether today's readiness
    /// push should fire now, at 7, at the honest fallback, or not at all —
    /// see the delivery-gating comment on the hour constants above.
    func refreshMorningNotification() {
        guard NotificationScheduler.shared.morningReadinessEnabled else {
            NotificationScheduler.shared.cancelMorningReadiness()
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
            NotificationScheduler.shared.cancelMorningReadiness()
            armFallbackForTomorrow(calendar: calendar, now: now)
            return
        }
        #endif

        if deliveredToday(now: now, calendar: calendar) {
            defaults.set(today, forKey: Self.lastFiredDayKey)
            armFallbackForTomorrow(calendar: calendar, now: now)
            return
        }

        guard let report = computeReport() else { return }
        let score = Int(report.displayScore * 100)

        // Sleep is attributed to the day it ENDED, so a metric dated today
        // carrying sleep or nocturnal HRV means last night has truly synced —
        // the score reflects this morning, not the previous one.
        let hasOvernightData = HealthMetricsStore.shared.metrics.contains {
            calendar.isDate($0.date, inSameDayAs: today)
                && ($0.sleepTotalMinutes != nil || $0.nocturnalHRV != nil)
        }

        let sevenAM = calendar.date(bySettingHour: Self.notifyHour, minute: 0, second: 0, of: now) ?? now
        let fallback = calendar.date(bySettingHour: Self.fallbackHour, minute: Self.fallbackMinute, second: 0, of: now) ?? now

        let fireDate: Date
        let body: String
        if hasOvernightData {
            // Real overnight numbers: 7 AM, or immediately when the sync
            // (which follows wake-up) arrived later than that.
            fireDate = max(now.addingTimeInterval(2), sevenAM)
            body = report.preWorkoutAdjustment
        } else {
            // Still asleep or the watch hasn't synced — hold for the observer
            // wake to upgrade this; if nothing lands by mid-morning, say so.
            fireDate = max(now.addingTimeInterval(2), fallback)
            body = report.preWorkoutAdjustment + " (Last night's sleep hasn't synced yet.)"
        }
        defaults.set(fireDate, forKey: Self.scheduledFireKey)
        NotificationScheduler.shared.scheduleMorningReadiness(
            at: fireDate,
            title: "Readiness \(score) — \(report.action.title)",
            body: body
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

    /// Guaranteed baseline once today is done: tomorrow's fallback-time push
    /// with the caveat copy, computed from what's known now. Every overnight
    /// wake path upgrades it to the real thing before it ever fires — it only
    /// survives untouched when no background wake happened all night, in
    /// which case the caveat is accurate. Stamping its fire date is safe:
    /// both call sites persist today's delivery in `lastFiredDayKey` first,
    /// and the stamp is what stops a later wake from double-pushing after
    /// the fallback fired unattended.
    private func armFallbackForTomorrow(calendar: Calendar, now: Date) {
        guard let report = computeReport(),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let fireDate = calendar.date(bySettingHour: Self.fallbackHour, minute: Self.fallbackMinute, second: 0, of: tomorrow)
        else { return }
        let score = Int(report.displayScore * 100)
        UserDefaults.standard.set(fireDate, forKey: Self.scheduledFireKey)
        NotificationScheduler.shared.scheduleMorningReadiness(
            at: fireDate,
            title: "Readiness \(score) — \(report.action.title)",
            body: report.preWorkoutAdjustment + " (Last night's sleep hasn't synced yet.)"
        )
    }

    private func computeReport() -> RecoveryEngine.Report? {
        guard let container else { return nil }
        let context = container.mainContext
        let workouts = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        guard !workouts.isEmpty || !HealthMetricsStore.shared.metrics.isEmpty else { return nil }
        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        return ReadinessReportFactory.report(
            workouts: workouts,
            exercises: exercises,
            in: context
        )
    }

    private func nextOccurrence(hour: Int, minute: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        let todays = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if todays > now { return todays }
        return calendar.date(byAdding: .day, value: 1, to: todays) ?? todays
    }
}
