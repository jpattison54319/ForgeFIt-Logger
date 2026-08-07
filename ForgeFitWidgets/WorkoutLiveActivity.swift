import ActivityKit
import ForgeCore
import SwiftUI
import WidgetKit

/// Lock-screen and Dynamic Island presence for the active workout: elapsed
/// time, current exercise, set progress, live HR — and while resting, the
/// countdown takes over (the number the lifter actually needs on a locked
/// phone between sets). Cardio headlines pace/step; guided yoga headlines the
/// current pose with a native hold countdown.
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkoutView(context: context)
                .activityBackgroundTint(WActivityTheme.background)
                .activitySystemActionForegroundColor(WActivityTheme.accent)
                // Tap from the lock screen drops straight into the logger.
                .widgetURL(URL(string: "forgefit://workout"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.isStale ? "pause.circle.fill" : WActivityTheme.icon(for: context.state.mode))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(WActivityTheme.accent)
                        Text(context.isStale ? "Workout paused" : headerTitle(context))
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.isStale {
                        Text("Open app")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(WActivityTheme.accent)
                    } else {
                        elapsedText(context)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(WActivityTheme.gold)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.isStale {
                        Text("ForgeFit stopped receiving workout updates")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.center)
                    } else if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                        restCountdown(until: restEndsAt, size: 30)
                    } else if context.state.mode == .yoga {
                        VStack(spacing: 1) {
                            Text(context.state.cardioMetric ?? "In session")
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            if let poseEndsAt = context.state.poseEndsAt, poseEndsAt > .now {
                                Text(timerInterval: Date.now...poseEndsAt, countsDown: true)
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(WActivityTheme.accent)
                            }
                        }
                    } else if context.state.mode == .cardio || context.state.mode == .conditioning {
                        Text(context.state.cardioMetric ?? "Recording")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                    } else if let exercise = context.state.exerciseName {
                        VStack(spacing: 1) {
                            Text(exercise)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            if let next = context.state.nextExerciseName {
                                Text("Next: \(next)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.isStale ? "Open ForgeFit to resume or finish" : detailLine(context))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WActivityTheme.accent)
                            .lineLimit(1)
                        Spacer()
                        if !context.isStale, let hr = context.state.heartRate {
                            Label("\(hr)", systemImage: "heart.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(WActivityTheme.danger)
                        }
                    }
                }
            } compactLeading: {
                if context.isStale {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(WActivityTheme.accent)
                } else if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    Image(systemName: "timer")
                        .foregroundStyle(WActivityTheme.accent)
                } else {
                    Image(systemName: WActivityTheme.icon(for: context.state.mode))
                        .foregroundStyle(WActivityTheme.accent)
                }
            } compactTrailing: {
                if context.isStale {
                    Text("Open")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(WActivityTheme.accent)
                } else if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    restCountdown(until: restEndsAt, size: 14)
                        .frame(maxWidth: 44)
                } else if context.state.mode == .yoga,
                          let poseEndsAt = context.state.poseEndsAt, poseEndsAt > .now {
                    // The current hold is the number a yogi glances for.
                    restCountdown(until: poseEndsAt, size: 14)
                        .frame(maxWidth: 44)
                } else {
                    elapsedText(context)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WActivityTheme.gold)
                        .frame(maxWidth: 52)
                }
            } minimal: {
                if context.isStale {
                    Image(systemName: "pause.circle.fill")
                        .foregroundStyle(WActivityTheme.accent)
                } else if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    restCountdown(until: restEndsAt, size: 11)
                } else if context.state.mode == .yoga,
                          let poseEndsAt = context.state.poseEndsAt, poseEndsAt > .now {
                    restCountdown(until: poseEndsAt, size: 11)
                } else {
                    Image(systemName: WActivityTheme.icon(for: context.state.mode))
                        .foregroundStyle(WActivityTheme.accent)
                }
            }
            .keylineTint(WActivityTheme.accent)
        }
        // The wrist is where a lifter actually glances mid-set. Without this
        // the watch Smart Stack falls back to a generic presentation;
        // `LockScreenWorkoutView` reads `\.activityFamily` and draws the one
        // number that matters — rest, hold, or elapsed — at watch scale.
        .supplementalActivityFamilies([.small])
    }

    private func headerTitle(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> String {
        switch context.state.mode {
        case .cardio, .conditioning, .yoga: context.state.cardioTitle ?? context.attributes.workoutTitle
        case .strength: context.attributes.workoutTitle
        }
    }

    private func detailLine(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> String {
        switch context.state.mode {
        case .cardio: context.state.cardioDetail ?? "Cardio"
        case .conditioning: context.state.cardioDetail ?? "Conditioning"
        case .yoga: context.state.cardioDetail ?? "Yoga"
        case .strength: "\(context.state.completedSets)/\(context.state.totalSets) sets"
        }
    }

    private func elapsedText(_ context: ActivityViewContext<WorkoutActivityAttributes>) -> Text {
        Text(context.state.startedAt, style: .timer)
    }

    private func restCountdown(until endsAt: Date, size: CGFloat) -> some View {
        Text(timerInterval: Date.now...endsAt, countsDown: true)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(WActivityTheme.accent)
    }
}

// MARK: - Lock screen

private struct LockScreenWorkoutView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>
    @Environment(\.activityFamily) private var family

    private var isSessionMode: Bool {
        context.state.mode == .cardio || context.state.mode == .conditioning || context.state.mode == .yoga
    }

    var body: some View {
        if context.isStale {
            staleBody
        } else {
            switch family {
            case .small: watchBody
            default: phoneBody
            }
        }
    }

    private var staleBody: some View {
        VStack(alignment: family == .small ? .center : .leading, spacing: 4) {
            Label("Workout paused", systemImage: "pause.circle.fill")
                .font(.system(size: family == .small ? 13 : 16, weight: .bold))
                .foregroundStyle(WActivityTheme.accent)
            Text("Open ForgeFit to resume or finish")
                .font(.system(size: family == .small ? 11 : 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(family == .small ? .center : .leading)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: family == .small ? .center : .leading)
        .padding(family == .small ? 8 : 16)
    }

    /// Apple Watch Smart Stack. A wrist glance mid-set is worth exactly one
    /// number, so the countdown or elapsed clock takes the whole card and the
    /// exercise name rides underneath it.
    private var watchBody: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: WActivityTheme.icon(for: context.state.mode))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(WActivityTheme.accent)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                watchTimer(until: restEndsAt, tint: WActivityTheme.accent)
            } else if context.state.mode == .yoga,
                      let poseEndsAt = context.state.poseEndsAt, poseEndsAt > .now {
                watchTimer(until: poseEndsAt, tint: WActivityTheme.accent)
            } else {
                Text(context.state.startedAt, style: .timer)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .foregroundStyle(WActivityTheme.gold)
            }
            Text(detailLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WActivityTheme.accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
    }

    private var headline: String {
        if let restEndsAt = context.state.restEndsAt, restEndsAt > .now { return "Rest" }
        if context.state.mode == .yoga,
           let poseEndsAt = context.state.poseEndsAt, poseEndsAt > .now { return "Hold" }
        if isSessionMode { return context.state.cardioTitle ?? context.attributes.workoutTitle }
        return context.state.exerciseName ?? context.attributes.workoutTitle
    }

    private func watchTimer(until endsAt: Date, tint: Color) -> some View {
        Text(timerInterval: Date.now...endsAt, countsDown: true)
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(tint)
    }

    private var phoneBody: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: WActivityTheme.icon(for: context.state.mode))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(WActivityTheme.accent)
                    Text(isSessionMode ? (context.state.cardioTitle ?? context.attributes.workoutTitle) : context.attributes.workoutTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if isSessionMode {
                    Text(context.state.cardioMetric ?? "Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                } else if let exercise = context.state.exerciseName {
                    Text(exercise)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    // What's coming, so the lifter can set up without
                    // reopening the app; the last exercise says so instead.
                    Text(context.state.nextExerciseName.map { "Next: \($0)" } ?? "Final exercise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(detailLine)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WActivityTheme.accent)
                        .lineLimit(1)
                    if let hr = context.state.heartRate {
                        Label("\(hr)", systemImage: "heart.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(WActivityTheme.danger)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    Text("REST")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(WActivityTheme.accent)
                    Text(timerInterval: Date.now...restEndsAt, countsDown: true)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(WActivityTheme.accent)
                        .frame(maxWidth: 90)
                } else if context.state.mode == .yoga,
                          let poseEndsAt = context.state.poseEndsAt, poseEndsAt > .now {
                    // The hold countdown is the yoga equivalent of the rest
                    // timer — the number that matters on a locked phone.
                    Text("HOLD")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(WActivityTheme.accent)
                    Text(timerInterval: Date.now...poseEndsAt, countsDown: true)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(WActivityTheme.accent)
                        .frame(maxWidth: 90)
                } else {
                    Text("ELAPSED")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(WActivityTheme.gold.opacity(0.8))
                    Text(context.state.startedAt, style: .timer)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(WActivityTheme.gold)
                        .frame(maxWidth: 110)
                }
            }
        }
        .padding(16)
    }

    private var detailLine: String {
        switch context.state.mode {
        case .cardio: context.state.cardioDetail ?? "Cardio"
        case .conditioning: context.state.cardioDetail ?? "Conditioning"
        case .yoga: context.state.cardioDetail ?? "Yoga"
        case .strength: "\(context.state.completedSets)/\(context.state.totalSets) sets"
        }
    }
}

/// Sage palette for EVERY widget surface — the Live Activity and the
/// launcher/lock-screen widgets (the extension has no app theme). Keep in
/// sync with `AppTheme.sage`; nothing here may fall back to `.purple` /
/// `.green` system colors (the launcher widget shipped the pre-sage purple
/// brand for months because it didn't share this palette).
enum WActivityTheme {
    static let background = Color(red: 14 / 255, green: 17 / 255, blue: 22 / 255)    // 0x0E1116 slate obsidian
    static let accent = Color(red: 85 / 255, green: 179 / 255, blue: 116 / 255)     // 0x55B374
    static let gold = Color(red: 245 / 255, green: 185 / 255, blue: 58 / 255)       // 0xF5B93A
    static let danger = Color(red: 255 / 255, green: 90 / 255, blue: 100 / 255)
    static let recoveryHigh = Color(red: 53 / 255, green: 208 / 255, blue: 122 / 255) // 0x35D07A

    static func icon(for mode: WorkoutActivityAttributes.WorkoutActivityMode) -> String {
        switch mode {
        case .strength: "dumbbell.fill"
        case .cardio: "figure.run"
        case .conditioning: "figure.cross.training"
        case .yoga: "figure.yoga"
        }
    }
}
