import Foundation

/// Opt-in "loud" rest-timer backstop (T3-4): for lifters whose phone lies
/// face-down across the gym and who miss the single rest-end chime.
/// Deliberately default-OFF: the notification + forge-strike chime remain
/// the primary path (see RestTimerController, TimerChime).
///
/// When enabled, `schedule(endsAt:title:)` asks NotificationScheduler to
/// follow the primary rest-end notification with a couple of extra
/// time-sensitive pings a few seconds apart — more noise, no UI to dismiss.
///
/// History: this used to schedule a real AlarmKit alarm, which reliably
/// broke through the hardware mute switch *and* Focus/Do Not Disturb — but
/// AlarmKit has no sound-only presentation. Every alarm that fires surfaces
/// `AlarmPresentation.Alert`, a full-screen system UI with a mandatory stop
/// button (per Apple's AlarmKit docs: WWDC25 "Wake up to the AlarmKit API",
/// https://developer.apple.com/videos/play/wwdc2025/230/, and
/// https://developer.apple.com/documentation/alarmkit/alarmpresentation/alert-swift.struct).
/// That alert screen was exactly the "opens up and I have to dismiss it"
/// behavior the user rejected, so it's gone — dropped 2026-07.
///
/// What replaced it: `UNNotificationInterruptionLevel.timeSensitive` (used
/// by the base rest-end notification and these follow-ups) already bypasses
/// Focus/Do Not Disturb filtering on its own — that is Apple's documented
/// contract for the interruption level — with zero alert UI, just a normal
/// banner + sound. The one thing it can't do that AlarmKit could is bypass
/// the *physical* ringer/mute switch; only `.critical` interruption level
/// does that, and it requires an Apple-granted Critical Alerts entitlement
/// (a case-by-case request, not something togglable from code). See the
/// integration report for the tradeoff writeup.
@MainActor
enum RestAlarm {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "loudRestAlarmEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "loudRestAlarmEnabled") }
    }

    /// The "loud" path rides on standard notification delivery now, not a
    /// separate alarm authorization — this just confirms/(re)requests
    /// notification permission so the follow-up pings can actually fire.
    static func requestAuthorization() async -> Bool {
        await NotificationScheduler.shared.requestPermission()
    }

    static func schedule(endsAt: Date, title: String) {
        guard isEnabled else { return }
        NotificationScheduler.shared.scheduleLoudRestEndFollowUps(after: endsAt, title: title)
    }

    static func cancel() {
        NotificationScheduler.shared.cancelLoudRestEndFollowUps()
    }
}
