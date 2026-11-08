import ForgeCore
import ForgeData
import SwiftUI

struct StrengthHoldLogRow: View {
    @Environment(\.theme) private var theme
    @State private var timer = StrengthHoldTimer.shared
    var grid = SetGridMetrics()

    let set: SetModel
    let number: Int
    let workoutID: UUID
    let exerciseID: UUID
    let defaultSeconds: Int
    let displayUnit: WeightUnit
    let showsLoad: Bool
    let supportsResistanceBands: Bool
    let showsPrevious: Bool
    let previous: String
    let stacksFields: Bool
    let pendingDrafts: PendingDraftCoordinator
    @Binding var openSwipeSetID: UUID?
    let isLive: Bool
    let onMatchPrevious: (() -> Void)?
    let onChange: () -> Void
    let onFinish: (Int, Date) -> Void
    let onReopen: () -> Void
    let onDelete: () -> Void

    private var completed: Bool { self.set.completedAt != nil }
    private var duration: Int { StrengthHold.validSeconds(set.durationSeconds) ?? defaultSeconds }
    private var currentHold: StrengthHoldTimer.Hold? {
        guard !completed, timer.hold?.setID == set.id else { return nil }
        return timer.hold
    }

    var body: some View {
        SwipeToDeleteRow(
            isOpen: openSwipeSetID == set.id,
            onOpenChange: { open in
                if open { openSwipeSetID = set.id }
                else if openSwipeSetID == set.id { openSwipeSetID = nil }
            },
            onDelete: onDelete
        ) {
            Group {
                if stacksFields {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: 6) {
                            completionButton
                            setMenu
                            previousValue
                        }
                        if showsLoad { loadField }
                        HStack(spacing: 6) {
                            durationField
                            timerButton
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        completionButton
                        setMenu
                        if showsPrevious { previousValue } else { Spacer(minLength: 0) }
                        if showsLoad {
                            loadField.frame(width: supportsResistanceBands ? grid.bandWeight : grid.weight)
                        }
                        durationField.frame(width: grid.holdTime)
                        timerButton
                    }
                }
            }
            .padding(6)
            .background(completed ? theme.success.opacity(0.12) : Color.clear)
            .animation(.snappy(duration: 0.2), value: completed)
        }
        .clipShape(.rect(cornerRadius: 8))
        .sensoryFeedback(.impact(weight: .medium), trigger: completed) { _, done in done }
    }

    private var completionButton: some View {
        SetCompletionButton(completed: completed, grid: grid) {
            if completed { onReopen() } else { finish() }
        }
        .accessibilityLabel(completed ? "Mark set \(number) incomplete" : "Mark set \(number) complete")
        .accessibilityHint(currentHold == nil ? "" : "Logs the time held")
        .accessibilityIdentifier(completed ? "reopen-timed-set" : "finish-timed-set")
    }

    private var setMenu: some View {
        ScrollSafeMenu(sections: menuSections) {
            HStack(spacing: 3) {
                Text(number.formatted()).font(.system(size: 15, weight: .bold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .foregroundStyle(theme.textPrimary)
            .frame(width: grid.setBadge, height: grid.fieldHeight)
            .contentShape(.rect)
        }
        .accessibilityLabel(completed ? "Set \(number), complete, options" : "Set \(number), options")
        .accessibilityIdentifier(completed ? "timed-set-completed" : "timed-set-pending")
    }

    private var previousValue: some View {
        Button {
            pendingDrafts.commit(set.id)
            hideKeyboard()
            onMatchPrevious?()
        } label: {
            Text(previous)
                .font(.system(size: 14))
                .foregroundStyle(onMatchPrevious == nil ? theme.textTertiary : theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
                .minimumTouchTarget()
        }
        .buttonStyle(.plain)
        .disabled(onMatchPrevious == nil || currentHold != nil)
        .accessibilityHint(onMatchPrevious == nil ? "" : "Copies your previous set into this one")
    }

    private var loadField: some View {
        StrengthSetLoadField(
            weight: set.modeWeight, unit: displayUnit, supportsResistanceBands: supportsResistanceBands,
            compact: !stacksFields, pendingDrafts: pendingDrafts, setID: set.id
        ) { weight in
            set.setModeWeight(weight)
            onChange()
        }
        .disabled(currentHold != nil)
    }

    @ViewBuilder
    private var durationField: some View {
        if let hold = currentHold {
            if hold.isPaused {
                let seconds = hold.elapsed > .zero ? max(1, Int(hold.elapsed.components.seconds)) : 0
                clock(seconds: seconds, isPaused: true)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    clock(seconds: hold.remaining(at: .now), isPaused: false)
                }
            }
        } else {
            StrengthHoldDurationButton(
                seconds: duration, identifier: "timed-set-duration", height: grid.fieldHeight,
                accessibilityTitle: "Duration for set \(number)"
            ) {
                set.durationSeconds = $0
                onChange()
            }
        }
    }

    private func clock(seconds: Int, isPaused: Bool) -> some View {
        let time = Fmt.elapsed(seconds)
        return VStack(spacing: 0) {
            Text(time).font(.bodyStrong.monospacedDigit())
            Text(isPaused ? "Held" : "Left").font(.tag).foregroundStyle(theme.textSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: .infinity, minHeight: grid.fieldHeight)
        .background(theme.surfaceElevated, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Time held for set \(number), paused" : "Time remaining for set \(number)")
        .accessibilityValue(time)
        .accessibilityIdentifier(isPaused ? "hold-paused" : "hold-running")
    }

    @ViewBuilder
    private var timerButton: some View {
        if completed || !isLive {
            Color.clear.frame(width: grid.check, height: grid.fieldHeight).accessibilityHidden(true)
        } else if let hold = currentHold {
            playbackButton(
                hold.isPaused ? "Resume timer for set \(number)" : "Pause timer for set \(number)",
                symbol: hold.isPaused ? "play.fill" : "pause.fill"
            ) {
                if hold.isPaused { timer.resume(setID: set.id) } else { timer.pause(setID: set.id) }
            }
            .accessibilityIdentifier(hold.isPaused ? "resume-hold" : "pause-hold")
        } else {
            playbackButton("Start timer for set \(number)", symbol: "play.fill", action: start)
                .disabled(timer.hold != nil)
                .opacity(timer.hold == nil ? 1 : 0.45)
                .accessibilityIdentifier("start-hold")
        }
    }

    private func playbackButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.bodyStrong)
                .foregroundStyle(theme.accentForeground)
                .frame(width: grid.check, height: grid.fieldHeight)
                .background(theme.surfaceElevated, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(title)
    }

    private var menuSections: [[ScrollSafeMenuItem]] {
        let delete = [ScrollSafeMenuItem(
            title: "Delete Set", systemImage: "trash", isDestructive: true, action: onDelete
        )]
        guard currentHold != nil else { return [delete] }
        return [[ScrollSafeMenuItem(title: "Reset Timer", systemImage: "arrow.counterclockwise") {
            timer.cancel(setID: set.id)
        }], delete]
    }

    private func start() {
        guard timer.hold == nil else { return }
        pendingDrafts.commit(set.id)
        hideKeyboard()
        let finish = onFinish
        RestTimerController.shared.skip()
        timer.start(workoutID: workoutID, exerciseID: exerciseID, setID: set.id, seconds: duration) { seconds, date in
            finish(seconds, date)
        }
    }

    private func finish() {
        if currentHold != nil {
            timer.finish(setID: set.id)
        } else {
            pendingDrafts.commit(set.id)
            hideKeyboard()
            onFinish(duration, .now)
        }
    }
}
