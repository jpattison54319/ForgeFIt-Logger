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
    /// The set that started the current micro-rest, so only its block shows
    /// the inline countdown.
    private(set) var microOwnerID: UUID?

    @ObservationIgnored private var completionTask: Task<Void, Never>?

    var isRunning: Bool {
        guard let endsAt else { return false }
        return endsAt > Date()
    }

    func remaining(at date: Date = Date()) -> Int {
        guard let endsAt else { return 0 }
        return max(0, Int(endsAt.timeIntervalSince(date).rounded(.up)))
    }

    func start(seconds: Int, label: String, micro: Bool = false, ownerID: UUID? = nil) {
        guard seconds > 0 else { return }
        totalSeconds = seconds
        endsAt = Date().addingTimeInterval(TimeInterval(seconds))
        self.label = label
        isMicro = micro
        microOwnerID = micro ? ownerID : nil
        scheduleCompletionHaptic()
        scheduleLockScreenNotification()
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
        completionTask?.cancel()
        cancelLockScreenNotification()
        endsAt = nil
        isMicro = false
        microOwnerID = nil
    }

    private func scheduleCompletionHaptic() {
        completionTask?.cancel()
        guard let endsAt else { return }
        let interval = endsAt.timeIntervalSinceNow
        completionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            #if canImport(UIKit)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            #endif
            self?.endsAt = nil
            self?.isMicro = false
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
        Task { @MainActor in
            NotificationScheduler.shared.scheduleRestEnd(at: endsAt)
        }
    }

    private func cancelLockScreenNotification() {
        Task { @MainActor in
            NotificationScheduler.shared.cancelRestEnd()
        }
    }
}

// MARK: - Countdown pill

/// Live glass countdown shown in the logger header while resting. −15 / +15 /
/// Skip are exposed directly (not behind a menu tap) so adjusting rest
/// mid-set is a single tap, matching the pace of actually lifting.
struct RestTimerPill: View {
    @Environment(\.theme) private var theme
    var timer = RestTimerController.shared

    var body: some View {
        if timer.isRunning {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = timer.remaining(at: context.date)
                let fraction = timer.totalSeconds > 0 ? Double(remaining) / Double(timer.totalSeconds) : 0
                let tint = timer.isMicro ? theme.secondaryAccent : theme.accent

                HStack(spacing: 6) {
                    Button { timer.adjust(by: -15) } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Subtract 15 seconds")

                    HStack(spacing: 7) {
                        ZStack {
                            Circle().stroke(tint.opacity(0.25), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: fraction)
                                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 18, height: 18)
                        .animation(.linear(duration: 0.5), value: fraction)
                        Text(Fmt.restTimer(remaining))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                            .contentTransition(.numericText(countsDown: true))
                    }

                    Button { timer.adjust(by: 15) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add 15 seconds")

                    Rectangle().fill(tint.opacity(0.3)).frame(width: 1, height: 16)

                    Button { timer.skip() } label: {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip rest")
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: 40)
                .glassEffect(.regular.tint(tint.opacity(0.28)).interactive(), in: Capsule())
                .transition(.scale.combined(with: .opacity))
            }
        }
    }
}

/// Compact inline countdown bar for intra-set micro-rests (inside myo-rep /
/// cluster blocks) — the lifter never leaves the card.
struct MicroRestBar: View {
    @Environment(\.theme) private var theme
    var timer = RestTimerController.shared
    let tint: Color
    var ownerID: UUID?

    var body: some View {
        if timer.isRunning && timer.isMicro && (ownerID == nil || timer.microOwnerID == ownerID) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let remaining = timer.remaining(at: context.date)
                let fraction = timer.totalSeconds > 0 ? Double(remaining) / Double(timer.totalSeconds) : 0
                HStack(spacing: Space.sm) {
                    Image(systemName: "timer")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tint.opacity(0.18))
                            Capsule().fill(tint).frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 5)
                    .animation(.linear(duration: 0.5), value: fraction)
                    Text("\(remaining)s")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .frame(width: 34, alignment: .trailing)
                    Button("Skip") { timer.skip() }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Skip micro-rest")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(tint.opacity(0.10))
                .clipShape(Capsule())
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
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
