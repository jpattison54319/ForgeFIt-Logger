import Foundation
import Observation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Single owner of every local notification the app sends:
/// - the rest-timer's lock-screen alert (scheduled by RestTimerController),
/// - weekly workout reminders (user-picked weekdays + time),
/// - the streak-protection nudge (evening alert when today would break an
///   active streak).
///
/// Permission is requested explicitly from the Settings Reminders card —
/// never silently mid-workout.
@MainActor
@Observable
final class NotificationScheduler: NSObject {
    static let shared = NotificationScheduler()

    enum NotificationID {
        static let restTimer = "forgefit.rest-timer"
        static let streakNudge = "forgefit.streak-nudge"
        static let intervalCue = "forgefit.interval-cue"
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

    var streakNudgeEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "streakNudgeEnabled") == nil
                || UserDefaults.standard.bool(forKey: "streakNudgeEnabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "streakNudgeEnabled")
            if !newValue { cancelStreakNudge() }
        }
    }

    /// The streak nudge fires at 19:00 — late enough to matter, early enough
    /// to act on.
    private static let nudgeHour = 19

    func activate() {
        UNUserNotificationCenter.current().delegate = self
        refreshStatus()
    }

    func refreshStatus() {
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

    func scheduleRestEnd(at endsAt: Date) {
        cancelRestEnd()
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            let interval = endsAt.timeIntervalSinceNow
            guard interval > 1 else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest over"
            content.body = "Time for your next set."
            content.sound = .default
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

    // MARK: - Streak-protection nudge

    /// One-shot evening alert, scheduled only while an active streak (≥ 2
    /// days) would break today. Recomputed on foreground; cancelled the
    /// moment a workout is finished today.
    func refreshStreakNudge(streak: Int, trainedToday: Bool) {
        guard streakNudgeEnabled, streak >= 2, !trainedToday else {
            cancelStreakNudge()
            return
        }
        let calendar = Calendar.current
        guard let fireDate = calendar.date(
            bySettingHour: Self.nudgeHour, minute: 0, second: 0, of: Date()
        ), fireDate > Date() else {
            // Past tonight's nudge time — nothing to schedule today.
            cancelStreakNudge()
            return
        }
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized else { return }
            center.removePendingNotificationRequests(withIdentifiers: [NotificationID.streakNudge])
            let content = UNMutableNotificationContent()
            content.title = "Keep your \(streak)-day streak alive"
            content.body = "A quick session tonight keeps it going."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fireDate.timeIntervalSinceNow, repeats: false
            )
            try? await center.add(UNNotificationRequest(
                identifier: NotificationID.streakNudge, content: content, trigger: trigger
            ))
        }
    }

    func cancelStreakNudge() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [NotificationID.streakNudge])
    }
}

extension NotificationScheduler: UNUserNotificationCenterDelegate {
    /// Foreground presentation: reminders and nudges show a banner; the
    /// rest-timer alert stays suppressed (the in-app haptic covers it).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.identifier == NotificationID.restTimer ? [] : [.banner, .sound]
    }
}
