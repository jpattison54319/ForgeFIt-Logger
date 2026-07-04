import ActivityKit
import ForgeCore
import SwiftUI
import WidgetKit

/// Lock-screen and Dynamic Island presence for the active workout: elapsed
/// time, current exercise, set progress, live HR — and while resting, the
/// countdown takes over (the number the lifter actually needs on a locked
/// phone between sets).
struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenWorkoutView(context: context)
                .activityBackgroundTint(WActivityTheme.background)
                .activitySystemActionForegroundColor(WActivityTheme.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: context.state.mode == .cardio ? "figure.run" : "dumbbell.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(WActivityTheme.accent)
                        Text(context.state.mode == .cardio ? (context.state.cardioTitle ?? context.attributes.workoutTitle) : context.attributes.workoutTitle)
                            .font(.system(size: 14, weight: .bold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedText(context)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WActivityTheme.gold)
                }
                DynamicIslandExpandedRegion(.center) {
                    if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                        restCountdown(until: restEndsAt, size: 30)
                    } else if context.state.mode == .cardio {
                        Text(context.state.cardioMetric ?? "Recording")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                    } else if let exercise = context.state.exerciseName {
                        Text(exercise)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.mode == .cardio ? (context.state.cardioDetail ?? "Cardio") : "\(context.state.completedSets)/\(context.state.totalSets) sets")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WActivityTheme.accent)
                            .lineLimit(1)
                        Spacer()
                        if let hr = context.state.heartRate {
                            Label("\(hr)", systemImage: "heart.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(WActivityTheme.danger)
                        }
                    }
                }
            } compactLeading: {
                if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    Image(systemName: "timer")
                        .foregroundStyle(WActivityTheme.accent)
                } else if context.state.mode == .cardio {
                    Image(systemName: "figure.run")
                        .foregroundStyle(WActivityTheme.accent)
                } else {
                    Image(systemName: "dumbbell.fill")
                        .foregroundStyle(WActivityTheme.accent)
                }
            } compactTrailing: {
                if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    restCountdown(until: restEndsAt, size: 14)
                        .frame(maxWidth: 44)
                } else {
                    elapsedText(context)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WActivityTheme.gold)
                        .frame(maxWidth: 52)
                }
            } minimal: {
                if let restEndsAt = context.state.restEndsAt, restEndsAt > .now {
                    restCountdown(until: restEndsAt, size: 11)
                } else {
                    Image(systemName: "dumbbell.fill")
                        .foregroundStyle(WActivityTheme.accent)
                }
            }
            .keylineTint(WActivityTheme.accent)
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

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: context.state.mode == .cardio ? "figure.run" : "dumbbell.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(WActivityTheme.accent)
                    Text(context.state.mode == .cardio ? (context.state.cardioTitle ?? context.attributes.workoutTitle) : context.attributes.workoutTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                if context.state.mode == .cardio {
                    Text(context.state.cardioMetric ?? "Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                } else if let exercise = context.state.exerciseName {
                    Text(exercise)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(context.state.mode == .cardio ? (context.state.cardioDetail ?? "Cardio") : "\(context.state.completedSets)/\(context.state.totalSets) sets")
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
}

/// Sage palette for the activity surfaces (extension has no app theme).
enum WActivityTheme {
    static let background = Color(red: 14 / 255, green: 17 / 255, blue: 22 / 255)    // 0x0E1116 slate obsidian
    static let accent = Color(red: 85 / 255, green: 179 / 255, blue: 116 / 255)     // 0x55B374
    static let gold = Color(red: 245 / 255, green: 185 / 255, blue: 58 / 255)       // 0xF5B93A
    static let danger = Color(red: 255 / 255, green: 90 / 255, blue: 100 / 255)
}
