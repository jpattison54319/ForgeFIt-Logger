import ForgeCore
import Observation
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Contextual rest defaults

/// Every set type carries a sensible rest default so the timer is contextual:
/// straight work gets minutes, intra-set structures get seconds. Users can
/// always override per exercise (`restSeconds` / `microRestSeconds`).
extension SetType {
    /// Rest after completing a whole set of this type. nil = no timer (drops
    /// happen back-to-back with zero rest).
    var defaultRestSeconds: Int? {
        switch self {
        case .warmup: 60
        case .working, .backoff: 120
        case .amrap: 180
        case .drop: nil
        case .myoRep, .restPause, .cluster: 120 // after the whole block
        }
    }

    /// Micro-rest between segments inside one set of this type.
    var defaultMicroRestSeconds: Int? {
        switch self {
        case .myoRep: 15
        case .restPause, .cluster: 20
        default: nil
        }
    }

    /// Whether this type logs as an intra-set block (activation/segments +
    /// micro-rests) instead of a flat row.
    var isBlockType: Bool {
        self == .myoRep || self == .restPause || self == .cluster
    }
}

// MARK: - Rest timer controller

/// One app-wide rest countdown. Starting a new one replaces the old — you only
/// ever rest from your most recent set. Fires a haptic when it hits zero.
@Observable
final class RestTimerController {
    static let shared = RestTimerController()

    private(set) var endsAt: Date?
    private(set) var totalSeconds: Int = 0
    private(set) var label: String = "Rest"
    /// True while the block micro-rest is running (styles the pill teal).
    private(set) var isMicro = false
    /// The set that started the current countdown — used to replace a block's
    /// own micro-rest on completion and to scope the AMRAP controls.
    private(set) var ownerID: UUID?
    /// The micro-rest's owner (nil for full rests / AMRAP windows).
    var microOwnerID: UUID? { isMicro ? ownerID : nil }

    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var soundOnEnd = false
    @ObservationIgnored private var endNotification: (title: String, body: String)?
    @ObservationIgnored private var onComplete: ((Int) -> Void)?

    var isRunning: Bool {
        guard let endsAt else { return false }
        return endsAt > Date()
    }

    func remaining(at date: Date = Date()) -> Int {
        guard let endsAt else { return 0 }
        return max(0, Int(endsAt.timeIntervalSince(date).rounded(.up)))
    }

    /// - Parameters:
    ///   - soundOnEnd: play an audible cue (plus the haptic) at zero — used by
    ///     AMRAP windows, where the lifter is mid-set and not looking down.
    ///   - endNotification: lock-screen copy at zero; defaults to rest copy.
    ///   - onComplete: called with the seconds actually run when the countdown
    ///     hits zero, is skipped, or gets replaced by a new timer.
    func start(
        seconds: Int,
        label: String,
        micro: Bool = false,
        ownerID: UUID? = nil,
        soundOnEnd: Bool = false,
        endNotification: (title: String, body: String)? = nil,
        onComplete: ((Int) -> Void)? = nil
    ) {
        guard seconds > 0 else { return }
        fireCompletionCallback()
        totalSeconds = seconds
        endsAt = Date().addingTimeInterval(TimeInterval(seconds))
        self.label = label
        isMicro = micro
        self.ownerID = ownerID
        self.soundOnEnd = soundOnEnd
        self.endNotification = endNotification
        self.onComplete = onComplete
        scheduleCompletionHaptic()
        scheduleLockScreenNotification()
    }

    /// Hand the seconds actually run to whoever started the countdown (AMRAP
    /// writes them onto the set). Fired exactly once per started timer —
    /// natural end, skip, or replacement, whichever comes first.
    private func fireCompletionCallback() {
        guard let onComplete else { return }
        self.onComplete = nil
        onComplete(max(0, totalSeconds - remaining()))
    }

    func adjust(by delta: Int) {
        guard let current = endsAt else { return }
        let target = max(Date().addingTimeInterval(1), current.addingTimeInterval(TimeInterval(delta)))
        endsAt = target
        totalSeconds = max(totalSeconds + delta, remaining())
        scheduleCompletionHaptic()
        scheduleLockScreenNotification()
    }

    func skip() {
        fireCompletionCallback()
        completionTask?.cancel()
        cancelLockScreenNotification()
        endsAt = nil
        isMicro = false
        ownerID = nil
        soundOnEnd = false
        endNotification = nil
    }

    private func scheduleCompletionHaptic() {
        completionTask?.cancel()
        guard let endsAt else { return }
        let interval = endsAt.timeIntervalSinceNow
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            // The forge-strike chime, but only when it lands on time: a
            // suspended app resumes this task on return, and a chime firing
            // minutes late (the notification already covered it) reads as a
            // bug, not a cue.
            if let endsAt = self.endsAt, Date().timeIntervalSince(endsAt) < 3 {
                TimerChime.shared.play()
            }
            // Foreground completion: the in-app chime just covered it — the
            // opt-in loud backstop (RestAlarm) must not also ping seconds
            // later.
            RestAlarm.cancel()
            self.fireCompletionCallback()
            self.endsAt = nil
            self.isMicro = false
            self.ownerID = nil
            self.soundOnEnd = false
            self.endNotification = nil
        }
    }

    // MARK: - Lock-screen delivery

    /// The in-app haptic only fires in the foreground; a local notification at
    /// rest-end covers the (typical) case where the phone is locked between
    /// sets. Delivery is owned by NotificationScheduler (which never requests
    /// permission here — that happens explicitly in Settings). Micro-rests
    /// skip it: 15s is too short to lock your phone over.
    private func scheduleLockScreenNotification() {
        guard let endsAt, !isMicro else { return }
        let notification = endNotification
        Task { @MainActor in
            NotificationScheduler.shared.scheduleRestEnd(
                at: endsAt,
                title: notification?.title ?? "Rest over",
                body: notification?.body ?? "Time for your next set."
            )
            // Opt-in loud backstop: a couple of extra time-sensitive pings
            // behind the notification above (no-ops unless enabled in
            // Settings) — no alarm UI, just more noise.
            RestAlarm.schedule(endsAt: endsAt, title: notification?.title ?? "Rest over")
        }
    }

    private func cancelLockScreenNotification() {
        Task { @MainActor in
            NotificationScheduler.shared.cancelRestEnd()
            RestAlarm.cancel()
        }
    }
}

// MARK: - Countdown bar

/// Full-width rest countdown strip shown under the logger's stats bar while
/// resting: a right-to-left draining progress line, the remaining time, and
/// direct −15 / +15 / Skip controls (no menu tap) at full 44pt targets.
///
/// Structure matters here: only the progress line + time live inside the
/// half-second `TimelineView` — the three buttons sit OUTSIDE it as stable
/// views. The previous pill design recreated its Buttons on every tick,
/// which dropped in-flight taps (the reported "skip / +/− don't work" bug)
/// and had no room in the top bar to breathe.
struct RestTimerBar: View {
    @Environment(\.theme) private var theme
    var timer = RestTimerController.shared

    var body: some View {
        if timer.isRunning {
            let tint = timer.isMicro ? theme.secondaryAccent : theme.accent

            HStack(spacing: Space.sm) {
                Button { timer.adjust(by: -15) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)   // HIG minimum touch target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Subtract 15 seconds")

                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let remaining = timer.remaining(at: context.date)
                    let fraction = timer.totalSeconds > 0 ? Double(remaining) / Double(timer.totalSeconds) : 0

                    HStack(spacing: Space.md) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(tint.opacity(0.18))
                                Capsule()
                                    .fill(tint)
                                    .frame(width: max(6, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 6)
                        .animation(.linear(duration: 0.5), value: fraction)

                        Text(Fmt.restTimer(remaining))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                            .contentTransition(.numericText(countsDown: true))
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
                .frame(height: 44)

                Button { timer.adjust(by: 15) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 44, height: 44)   // HIG minimum touch target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add 15 seconds")

                Button { timer.skip() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)   // HIG minimum touch target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip rest")
                .accessibilityIdentifier("skip-rest-timer")
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Space.md)
            .glassEffect(.regular.tint(tint.opacity(0.22)), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Rest duration picker

/// Menu of rest durations, used for the per-exercise "Rest Timer" row and the
/// micro-rest chip — users can always change the timer value.
struct RestDurationMenu<Label: View>: View {
    @Environment(\.theme) private var theme
    let options: [Int]
    let allowsOff: Bool
    let selected: Int?
    let onPick: (Int?) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            if allowsOff {
                Button { onPick(0) } label: {
                    SwiftUI.Label("Off", systemImage: selected == 0 ? "checkmark" : "")
                }
            }
            ForEach(options, id: \.self) { seconds in
                Button { onPick(seconds) } label: {
                    SwiftUI.Label(Fmt.restTimer(seconds), systemImage: selected == seconds ? "checkmark" : "")
                }
            }
        } label: {
            label()
        }
    }
}
