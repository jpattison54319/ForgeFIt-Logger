import Foundation
import Observation
import OSLog
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

actor RestAlertDeliveryCoordinator {
    enum Owner {
        case inApp
        case system
        case cancelled
    }

    static let shared = RestAlertDeliveryCoordinator()

    private struct Claim {
        let owner: Owner
        let createdAt: Date
    }
    private var claims: [String: Claim] = [:]

    /// Exactly one foreground sound path owns a primary rest alert.
    func claim(_ identifier: String, owner: Owner, now: Date = Date()) -> Bool {
        purgeExpired(now: now)
        guard claims[identifier] == nil else { return false }
        claims[identifier] = Claim(owner: owner, createdAt: now)
        return true
    }

    /// A cancelled/replaced timer must suppress a request that was already in
    /// flight to UserNotifications and could otherwise arrive stale.
    func cancel(_ identifier: String, now: Date = Date()) {
        purgeExpired(now: now)
        claims[identifier] = Claim(owner: .cancelled, createdAt: now)
    }

    private func purgeExpired(now: Date) {
        claims = claims.filter { now.timeIntervalSince($0.value.createdAt) < 300 }
    }
}

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

    nonisolated enum ForegroundDelivery: Equatable {
        case bannerAndSystemSound
        case inAppRestChime
        case systemSound
    }

    nonisolated enum NotificationID {
        static let restTimer = "forgefit.rest-timer"
        static func restTimerAlert(_ alertID: UUID) -> String {
            "\(restTimer).alert.\(alertID.uuidString)"
        }
        static func isPrimaryRestTimer(_ identifier: String) -> Bool {
            identifier.hasPrefix("\(restTimer).alert.")
        }
        static func isRestTimer(_ identifier: String) -> Bool {
            identifier.hasPrefix(restTimer)
        }
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

    /// Foreground rest completion must use the app's `.playback` audio session:
    /// unlike a notification sound, it follows the current media route, ducks
    /// Spotify, and remains audible with the ringer switch off. Only background
    /// delivery and the opt-in follow-up pings stay system-owned.
    nonisolated static func foregroundDelivery(for identifier: String) -> ForegroundDelivery {
        guard NotificationID.isRestTimer(identifier) else { return .bannerAndSystemSound }
        return NotificationID.isPrimaryRestTimer(identifier) ? .inAppRestChime : .systemSound
    }

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @ObservationIgnored private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ForgeFit",
        category: "NotificationScheduler"
    )

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

    /// Returns true only when the system accepted an audible request. Foreground
    /// ownership is arbitrated separately by `RestAlertDeliveryCoordinator`.
    func scheduleRestEnd(
        alertID: UUID,
        at endsAt: Date,
        title: String = "Rest over",
        body: String = "Time for your next set."
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return false
        }
        let interval = endsAt.timeIntervalSinceNow
        guard interval > 1 else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Same forge-strike chime as the in-app timer, so the locked phone
        // sounds like ForgeFit. Respect the app-level timer-sound toggle on
        // both foreground and background delivery paths.
        if TimerChime.isEnabled {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(TimerChime.soundFileName))
        }
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: NotificationID.restTimerAlert(alertID),
                    content: content,
                    trigger: trigger
                )
            )
            return TimerChime.isEnabled
                && settings.authorizationStatus == .authorized
                && settings.soundSetting == .enabled
        } catch {
            logger.error("Failed to schedule rest alert: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func cancelRestEnd(alertID: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [NotificationID.restTimerAlert(alertID)])
    }

    func hasDeliveredRestEnd(alertID: UUID) async -> Bool {
        let identifier = NotificationID.restTimerAlert(alertID)
        return await UNUserNotificationCenter.current()
            .deliveredNotifications()
            .contains { $0.request.identifier == identifier }
    }

    func cancelAllRestEnds() {
        Task {
            let center = UNUserNotificationCenter.current()
            let pendingIdentifiers = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter(NotificationID.isRestTimer)
            let deliveredIdentifiers = await center.deliveredNotifications()
                .map(\.request.identifier)
                .filter(NotificationID.isRestTimer)
            center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers)
            center.removeDeliveredNotifications(withIdentifiers: deliveredIdentifiers)
        }
    }

    /// Remove every workout-scoped notification. Safe to call repeatedly from
    /// overlapping terminal paths.
    func cancelWorkoutCues() {
        cancelAllRestEnds()
        cancelLoudRestEndFollowUps()
        cancelCardioCues()
    }

    func cancelCardioCues() {
        cancelYogaCueSchedule()
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.intervalCue])
        center.removeDeliveredNotifications(withIdentifiers: [NotificationID.intervalCue])
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

    /// One-shot, data-ready morning alert. Replaced — not appended — when
    /// fresher overnight data lands so its content matches Home.
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

// The SDK protocol predates strict concurrency. `@preconcurrency` lets this
// @MainActor class own the callbacks; nonisolated witnesses can resume UIKit's
// cold-launch scene restoration from a worker thread and trigger an assertion.
extension NotificationScheduler: @preconcurrency UNUserNotificationCenterDelegate {
    /// A primary rest alert that reaches a foreground app always uses the
    /// ringer-switch-independent in-app player. Returning `.sound` here created
    /// a race with `RestTimerController`: the system could claim the alert just
    /// before the controller and silently replace the working media-audio path.
    /// Background delivery never calls this method and retains the scheduled
    /// custom notification sound. Loud follow-ups remain system-owned.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        switch Self.foregroundDelivery(for: identifier) {
        case .bannerAndSystemSound:
            return [.banner, .sound]
        case .systemSound:
            return [.sound]
        case .inAppRestChime:
            let ownsSound = await RestAlertDeliveryCoordinator.shared.claim(identifier, owner: .inApp)
            if ownsSound {
                TimerChime.shared.play()
            }
            return []
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let rawURL = response.notification.request.content.userInfo[
            ExperimentNotificationRoute.userInfoURLKey
        ] as? String,
              URL(string: rawURL) != nil else {
            return
        }
        // Persist first so a cold launch cannot lose the route before
        // ContentView subscribes to the in-process notification.
        UserDefaults.standard.set(
            rawURL,
            forKey: ExperimentNotificationRoute.pendingURLDefaultsKey
        )
        NotificationCenter.default.post(
            name: ExperimentNotificationRoute.openRequested,
            object: nil
        )
    }
}
