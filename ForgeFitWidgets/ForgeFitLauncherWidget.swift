import ForgeCore
import SwiftUI
import WidgetKit

struct ForgeFitLauncherEntry: TimelineEntry {
    let date: Date
    let snapshot: ForgeFitWidgetSnapshot?
}

struct ForgeFitLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> ForgeFitLauncherEntry {
        ForgeFitLauncherEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (ForgeFitLauncherEntry) -> Void) {
        completion(ForgeFitLauncherEntry(date: Date(), snapshot: ForgeFitWidgetSnapshotStore.load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ForgeFitLauncherEntry>) -> Void) {
        let snapshot = ForgeFitWidgetSnapshotStore.load()
        let refresh = snapshot?.mode == .activeWorkout ? 5 * 60 : 60 * 60
        completion(Timeline(
            entries: [ForgeFitLauncherEntry(date: Date(), snapshot: snapshot)],
            policy: .after(.now.addingTimeInterval(TimeInterval(refresh)))
        ))
    }
}

struct ForgeFitLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ForgeFitLauncher", provider: ForgeFitLauncherProvider()) { entry in
            ForgeFitLauncherView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("ForgeFit")
        .description("Open ForgeFit.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct ForgeFitLauncherView: View {
    let entry: ForgeFitLauncherEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .systemLarge:
            largeWidget
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.purple)
            }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ForgeFit")
                        .font(.headline)
                    Text("Open")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .accessoryInline:
            Label("ForgeFit", systemImage: "dumbbell.fill")
        default:
            Label("ForgeFit", systemImage: "dumbbell.fill")
        }
    }

    private var snapshot: ForgeFitWidgetSnapshot? { entry.snapshot }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            launcherIcon(size: 34)
            Spacer()
            if snapshot?.mode == .activeWorkout {
                Text(snapshot?.workoutTitle ?? "Workout")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(setProgressText)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.72))
            } else if let score = snapshot?.readinessScore {
                Text("\(score)% ready")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(snapshot?.readinessAction ?? "Open ForgeFit")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            } else {
                Text("ForgeFit")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Open workout")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding()
    }

    private var mediumWidget: some View {
        HStack(spacing: 16) {
            if snapshot?.mode == .activeWorkout {
                workoutProgressRing(size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    header("Active workout", icon: "figure.strengthtraining.traditional")
                    Text(snapshot?.workoutTitle ?? "Workout")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(snapshot?.currentExerciseName ?? "Keep going")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    metricRow
                }
            } else if let score = snapshot?.readinessScore {
                readinessRing(score: score, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    header("Readiness", icon: "heart.fill")
                    Text(snapshot?.readinessAction ?? "Open ForgeFit")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(snapshot?.readinessDetail ?? "Check today’s recommendation.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                    chipRow(limit: 2)
                }
            } else {
                launcherFallback(horizontal: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var largeWidget: some View {
        VStack(alignment: .leading, spacing: 14) {
            if snapshot?.mode == .activeWorkout {
                HStack {
                    launcherIcon(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        header("Active workout", icon: "figure.strengthtraining.traditional")
                        Text(snapshot?.workoutTitle ?? "Workout")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    Spacer()
                    workoutProgressRing(size: 58)
                }
                Text(snapshot?.currentExerciseName ?? "Next set")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                metricRow
                Spacer()
                Text(restText)
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.72))
            } else if let score = snapshot?.readinessScore {
                HStack {
                    launcherIcon(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        header("Today", icon: "heart.fill")
                        Text(snapshot?.readinessAction ?? "Open ForgeFit")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    readinessRing(score: score, size: 58)
                }
                Text(snapshot?.readinessDetail ?? "Check today’s recommendation.")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                chipRow(limit: 3)
                Spacer()
                Text("Updated \(snapshot?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "recently")")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.54))
            } else {
                launcherFallback(horizontal: false)
            }
        }
        .padding()
    }

    private func header(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(.white.opacity(0.62))
    }

    private var metricRow: some View {
        HStack(spacing: 10) {
            Label(setProgressText, systemImage: "checkmark.circle.fill")
            if let hr = snapshot?.heartRate {
                Label("\(hr) bpm", systemImage: "heart.fill")
            }
            if snapshot?.restEndsAt != nil {
                Label("Rest", systemImage: "timer")
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.white.opacity(0.74))
    }

    private func chipRow(limit: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array((snapshot?.reasonChips ?? []).prefix(limit)), id: \.self) { chip in
                Text(chip)
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var setProgressText: String {
        guard let snapshot else { return "Open" }
        return "\(snapshot.completedSets)/\(snapshot.totalSets) sets"
    }

    private var restText: String {
        guard let restEndsAt = snapshot?.restEndsAt else { return "Tap to open ForgeFit" }
        if restEndsAt > Date() { return "Rest timer running" }
        return "Rest complete"
    }

    private func readinessRing(score: Int, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private func workoutProgressRing(size: CGFloat) -> some View {
        let total = max(snapshot?.totalSets ?? 0, 1)
        let completed = min(snapshot?.completedSets ?? 0, total)
        return ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(completed) / CGFloat(total))
                .stroke(.purple, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(completed)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private func launcherFallback(horizontal: Bool) -> some View {
        Group {
            if horizontal {
                HStack(spacing: 16) {
                    launcherIcon(size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ForgeFit").font(.title3.bold()).foregroundStyle(.white)
                        Text("Open your workouts and recovery.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    launcherIcon(size: 52)
                    Text("ForgeFit").font(.title2.bold()).foregroundStyle(.white)
                    Text("Open your workouts and recovery.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
    }

    private func launcherIcon(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.purple.gradient)
            Image(systemName: "dumbbell.fill")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private extension ForgeFitWidgetSnapshot {
    static var placeholder: ForgeFitWidgetSnapshot {
        ForgeFitWidgetSnapshot(
            mode: .idle,
            readinessScore: 72,
            readinessAction: "Train as planned",
            readinessDetail: "Sleep okay and load steady.",
            reasonChips: ["Sleep okay", "Load steady"]
        )
    }
}
