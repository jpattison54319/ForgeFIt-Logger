import Foundation
import Observation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Single owner of every local notification the app sends:
/// - the rest-timer's lock-screen alert (scheduled by RestTimerController),
/// - weekly workout reminders (user-picked weekdays + time).
///
/// Permission is requested explicitly from the Settings Reminders card —
/// never silently mid-workout.
@MainActor
@Observable
final class NotificationScheduler: NSObject {
    static let shared = NotificationScheduler()

    nonisolated enum NotificationID {
        static let restTimer = "forgefit.rest-timer"
        /// RestAlarm's opt-in "loud" follow-ups: a couple of extra
        /// time-sensitive pings after the primary rest-end notification.
        /// Prefixed with `restTimer` so the foreground-suppression check
        /// below covers them for free.
        static func loudRestFollowUp(_ index: Int) -> String { "\(restTimer).loud.\(index)" }
        static let allLoudRestFollowUpIDs = (0..<2).map { loudRestFollowUp($0) }
        static let streakNudge = "forgefit.streak-nudge"
        static let intervalCue = "forgefit.interval-cue"
        static func yogaCue(_ index: Int) -> String { "forgefit.yoga-cue.\(index)" }
        /// A guided class never exceeds a few dozen holds; 64 is also the
        /// system's pending-notification ceiling.
        static let allYogaCueIDs = (0..<64).map { yogaCue($0) }
        static let wrappedReady = "forgefit.wrapped-ready"
        static let morningReadiness = "forgefit.morning-readiness"
        static func reminder(weekday: Int) -> String { "forgefit.reminder.\(weekday)" }
        static let allReminderIDs = (1...7).map { reminder(weekday: $0) }
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    // Persisted preferences (read by Settings too).
    var reminderWeekdays: Set<Int> {   // 1 = Sunday … 7 = Saturday (Calendar convention)
        get {
            Set(UserDefaults.standard.array(forKey: "reminderWeekdays") as? [Int] ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: "reminderWeekdays")
            rescheduleReminders()
        }
    }

    /// Minutes since midnight for the reminder time (default 17:30).
    var reminderMinutes: Int {
        get {
            UserDefaults.standard.object(forKey: "reminderMinutes") as? Int ?? (17 * 60 + 30)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "reminderMinutes")
            rescheduleReminders()
        }
    }

    var morningReadinessEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "morningReadinessEnabled") == nil
                || UserDefaults.standard.bool(forKey: "morningReadinessEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "morningReadinessEnabled")
            if !newValue { cancelMorningReadiness() }
        }
    }

    func activate() {
        UNUserNotificationCenter.current().delegate = self
        refreshStatus()
    }

    func refreshStatus() {
        // Clear any pending request left by app versions that still offered
        // streak protection.
        cancelStreakNudge()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            authorizationStatus = settings.authorizationStatus
        }
    }

    /// Explicit permission flow, triggered from Settings only.
    func requestPermission() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        refreshStatus()
        if granted { rescheduleReminders() }
        return granted
    }

    #if canImport(UIKit)
    /// Deep-link to the app's notification settings when permission was denied.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif

    // MARK: - Rest timer (scheduled by RestTimerController)

    func scheduleRestEnd(at endsAt: Date, title: String = "Rest over", body: String = "Time for your next set.") {
        cancelRestEnd()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let interval = endsAt.timeIntervalSinceNow
            guard interval > 1 else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // Same forge-strike chime as the in-app timer, so the locked
            // phone sounds like ForgeFit, not like every other app.
            content.sound = UNNotificationSound(named: UNNotificationSoundName(TimerChime.soundFileName))
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: NotificationID.restTimer, content: content, trigger: trigger)
            )
        }
    }

    func cancelRestEnd() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [NotificationID.restTimer])
    }

    // MARK: - Loud rest-timer backstop (opt-in, RestAlarm)

    /// Seconds after `endsAt` for each follow-up ping.
    private static let loudFollowUpDelays: [TimeInterval] = [6, 14]

    /// A couple of extra time-sensitive pings, a few seconds apart, behind
    /// the primary rest-end notification — RestAlarm's opt-in "make it
    /// louder" path for lifters who miss a single chime. Same custom sound,
    /// same time-sensitive interruption level as the primary notification
    /// (which is what actually bypasses Focus/Do Not Disturb) — no alert UI,
    /// just more noise.
    func scheduleLoudRestEndFollowUps(after endsAt: Date, title: String) {
        cancelLoudRestEndFollowUps()
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            for (index, delay) in Self.loudFollowUpDelays.enumerated() {
                let interval = endsAt.addingTimeInterval(delay).timeIntervalSinceNow
                guard interval > 1 else { continue }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = "Still resting — your next set is up."
                content.sound = UNNotificationSound(named: UNNotificationSoundName(TimerChime.soundFileName))
                content.interruptionLevel = .timeSensitive
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                try? await center.add(UNNotificationRequest(
                    identifier: NotificationID.loudRestFollowUp(index), content: content, trigger: trigger
                ))
            }
        }
    }

    func cancelLoudRestEndFollowUps() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: NotificationID.allLoudRestFollowUpIDs)
    }

    // MARK: - Interval cue

    /// Fire-now alert announcing the interval step just started, so the cue
    /// lands with a locked/pocketed phone during a cardio session.
    func scheduleIntervalCue(stepLabel: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = stepLabel
            content.body = "Next interval — go."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            // Deliver right away (0 interval isn't allowed → 0.1s).
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: NotificationID.intervalCue, content: content, trigger: trigger
            ))
        }
    }

    // MARK: - Yoga class backstop (scheduled while backgrounded)

    /// Pre-schedules one time-sensitive notification per remaining pose
    /// transition of a running guided class. iOS suspends the app shortly
    /// after backgrounding (intermittent TTS doesn't hold it open), so the
    /// wall-clock schedule is what keeps a locked-phone class moving.
    /// Cancelled when the app returns to the foreground and the in-process
    /// runner takes back over.
    func scheduleYogaCueSchedule(_ entries: [(label: String, fireAt: Date)]) {
        cancelYogaCueSchedule()
        guard !entries.isEmpty else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            for (index, entry) in entries.prefix(64).enumerated() {
                let interval = entry.fireAt.timeIntervalSinceNow
                guard interval > 1 else { continue }
                let content = UNMutableNotificationContent()
                content.title = entry.label
                content.body = "Move into your next pose."
                content.sound = .default
                content.interruptionLevel = .timeSensitive
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
                try? await center.add(UNNotificationRequest(
                    identifier: NotificationID.yogaCue(index), content: content, trigger: trigger
                ))
            }
        }
    }

    func cancelYogaCueSchedule() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: NotificationID.allYogaCueIDs)
    }

    // MARK: - Weekly workout reminders

    /// Rebuild the repeating per-weekday reminders from preferences.
    func rescheduleReminders() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: NotificationID.allReminderIDs)
        let weekdays = reminderWeekdays
        guard !weekdays.isEmpty else { return }
        let minutes = reminderMinutes
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            for weekday in weekdays {
                var components = DateComponents()
                components.weekday = weekday
                components.hour = minutes / 60
                components.minute = minutes % 60
                let content = UNMutableNotificationContent()
                content.title = "Time to train"
                content.body = "Your workout is waiting — jump back in."
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                try? await center.add(UNNotificationRequest(
                    identifier: NotificationID.reminder(weekday: weekday),
                    content: content,
                    trigger: trigger
                ))
            }
        }
    }

    // MARK: - Morning readiness (scheduled by ReadinessDelivery)

    /// One-shot 7 AM readiness alert. Replaced — not appended — every time
    /// fresher overnight data lands, so the pending content converges on the
    /// score the user would see on Home.
    func scheduleMorningReadiness(at fireDate: Date, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            center.removePendingNotificationRequests(withIdentifiers: [NotificationID.morningReadiness])
            let interval = fireDate.timeIntervalSinceNow
            guard interval > 1 else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: NotificationID.morningReadiness, content: content, trigger: trigger
            ))
        }
    }

    func cancelMorningReadiness() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [NotificationID.morningReadiness])
    }

    // MARK: - Wrapped

    /// One-shot "your Wrapped is ready" alert, fired right after a new
    /// report is generated (generation is launch/foreground-driven, so the
    /// notification lands the first time the app runs on/after the 1st).
    /// Silent when notifications aren't authorized — the Home card is the
    /// non-pushy affordance.
    func scheduleWrappedReady(reportTitle: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            center.removePendingNotificationRequests(withIdentifiers: [NotificationID.wrappedReady])
            let content = UNMutableNotificationContent()
            content.title = "Your \(reportTitle) is ready"
            content.body = "See what you built last month and what to focus on next."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            try? await center.add(UNNotificationRequest(
                identifier: NotificationID.wrappedReady, content: content, trigger: trigger
            ))
        }
    }

    private func cancelStreakNudge() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [NotificationID.streakNudge])
    }
}

extension NotificationScheduler: UNUserNotificationCenterDelegate {
    /// Foreground presentation: reminders and alerts show a banner; the
    /// rest-timer alert (and its opt-in loud follow-ups, prefix-matched)
    /// stays suppressed — the in-app haptic + forge-strike chime cover it,
    /// and RestAlarm.cancel() already pulls any pending follow-ups the
    /// moment the foreground completion fires.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(NotificationID.restTimer) ? [] : [.banner, .sound]
    }
}
