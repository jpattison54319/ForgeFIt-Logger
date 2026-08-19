import ForgeCore
import SwiftUI
import WidgetKit

struct ForgeFitLauncherEntry: TimelineEntry {
    let date: Date
    let snapshot: ForgeFitWidgetSnapshot?
    let themePreference: ForgeThemePreference

    /// Smart Stack ranking: an active workout is THE moment this widget
    /// matters — bid maximum relevance so it surfaces mid-session; idle
    /// readiness bids modestly.
    var relevance: TimelineEntryRelevance? {
        snapshot?.mode == .activeWorkout
            ? TimelineEntryRelevance(score: 100)
            : TimelineEntryRelevance(score: 10)
    }
}

struct ForgeFitLauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> ForgeFitLauncherEntry {
        ForgeFitLauncherEntry(
            date: Date(),
            snapshot: .placeholder,
            themePreference: ForgeThemePreference()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ForgeFitLauncherEntry) -> Void) {
        completion(ForgeFitLauncherEntry(
            date: Date(),
            snapshot: ForgeFitWidgetSnapshotStore.load() ?? .placeholder,
            themePreference: ForgeThemePreferenceStore.load()
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ForgeFitLauncherEntry>) -> Void) {
        let snapshot = ForgeFitWidgetSnapshotStore.load()
        let refresh = snapshot?.mode == .activeWorkout ? 5 * 60 : 60 * 60
        completion(Timeline(
            entries: [ForgeFitLauncherEntry(
                date: Date(),
                snapshot: snapshot,
                themePreference: ForgeThemePreferenceStore.load()
            )],
            policy: .after(.now.addingTimeInterval(TimeInterval(refresh)))
        ))
    }
}

struct ForgeFitLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ForgeFitLauncher", provider: ForgeFitLauncherProvider()) { entry in
            ForgeFitLauncherView(entry: entry)
        }
        .configurationDisplayName("Readiness & Workout")
        .description("Today's readiness score and what it recommends — or live set progress while you're training.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct ForgeFitLauncherView: View {
    let entry: ForgeFitLauncherEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.colorScheme) private var colorScheme

    /// Home Screen widgets render in three modes. Only `.fullColor` gets the
    /// brand palette: in `.accented` the system splits the view into two
    /// groups and recolors them with the user's chosen tint, and in `.vibrant`
    /// it desaturates everything to a luminance map. Hardcoded white-on-black
    /// survives neither — it came out as a black slab on a tinted Home Screen.
    private var isFullColor: Bool { renderingMode == .fullColor }

    private var usesBrandedCanvas: Bool { isFullColor && !isAccessory }
    private var primaryText: Color { usesBrandedCanvas ? theme.textPrimary : .primary }
    private var secondaryText: Color { usesBrandedCanvas ? theme.textSecondary : .secondary }
    private var theme: ForgeWidgetTheme {
        ForgeWidgetTheme(
            preference: entry.themePreference,
            systemColorScheme: colorScheme
        )
    }
    private var accent: Color { isFullColor ? theme.accentForeground : .primary }

    var body: some View {
        content
            // Tap lands where the state points: mid-workout → the logger,
            // otherwise → Home's readiness (routed by ContentView's
            // handleDeepLink).
            .widgetURL(URL(string: snapshot?.mode == .activeWorkout ? "forgefit://workout" : "forgefit://readiness"))
            .containerBackground(for: .widget) {
                // Accessory (Lock Screen) families draw on the wallpaper and
                // must stay transparent; the tinted/vibrant Home Screen modes
                // supply their own material. The modifier still has to be
                // present in every case — WidgetKit requires one.
                if isFullColor, !isAccessory {
                    theme.background
                } else {
                    Color.clear
                }
            }
    }

    private var isAccessory: Bool {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        case .systemLarge:
            largeWidget
        // The accessory families hold the same snapshot the big widgets do —
        // they used to throw it away and show a bare dumbbell, which is the
        // one thing a Lock Screen slot can't afford.
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if snapshot?.mode == .activeWorkout {
                    VStack(spacing: 0) {
                        Image(systemName: "dumbbell.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("\(snapshot?.completedSets ?? 0)/\(snapshot?.totalSets ?? 0)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                } else if let score = snapshot?.readinessScore {
                    Gauge(value: Double(score), in: 0...100) {
                        Image(systemName: "bolt.heart.fill")
                    } currentValueLabel: {
                        Text("\(score)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                    .gaugeStyle(.accessoryCircular)
                } else {
                    Image(systemName: "bolt.heart.fill")
                        .font(.system(size: 18, weight: .bold))
                }
            }
            .accessibilityLabel(accessoryAccessibilityLabel)

        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: snapshot?.mode == .activeWorkout ? "dumbbell.fill" : "bolt.heart.fill")
                    .font(.system(size: 18, weight: .bold))
                VStack(alignment: .leading, spacing: 1) {
                    if snapshot?.mode == .activeWorkout {
                        Text(snapshot?.workoutTitle ?? "Workout").font(.headline).lineLimit(1)
                        Text("\(snapshot?.completedSets ?? 0) of \(snapshot?.totalSets ?? 0) sets")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let score = snapshot?.readinessScore {
                        Text("\(score)% ready").font(.headline)
                        Text(snapshot?.readinessAction ?? "Today's readiness")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("ForgeFit").font(.headline)
                        Text("Open to build your baseline")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)

        case .accessoryInline:
            if snapshot?.mode == .activeWorkout {
                Label("\(snapshot?.completedSets ?? 0)/\(snapshot?.totalSets ?? 0) sets", systemImage: "dumbbell.fill")
            } else if let score = snapshot?.readinessScore {
                Label("\(score)% ready", systemImage: "bolt.heart.fill")
            } else {
                Label("ForgeFit", systemImage: "dumbbell.fill")
            }

        default:
            Label("ForgeFit", systemImage: "dumbbell.fill")
        }
    }

    private var accessoryAccessibilityLabel: String {
        if snapshot?.mode == .activeWorkout {
            return "\(snapshot?.completedSets ?? 0) of \(snapshot?.totalSets ?? 0) sets complete"
        }
        if let score = snapshot?.readinessScore { return "\(score) percent ready" }
        return "ForgeFit"
    }

    private var snapshot: ForgeFitWidgetSnapshot? { entry.snapshot }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            launcherIcon(size: 34)
            Spacer()
            if snapshot?.mode == .activeWorkout {
                Text(snapshot?.workoutTitle ?? "Workout")
                    .font(.headline)
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                Text(setProgressText)
                    .font(.caption.bold())
                    .foregroundStyle(secondaryText)
            } else if let score = snapshot?.readinessScore {
                Text("\(score)% ready")
                    .font(.headline)
                    .foregroundStyle(primaryText)
                Text(snapshot?.readinessAction ?? "Open ForgeFit")
                    .font(.caption.bold())
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
            } else {
                Text("ForgeFit")
                    .font(.headline)
                    .foregroundStyle(primaryText)
                Text("Open workout")
                    .font(.caption)
                    .foregroundStyle(secondaryText)
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
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Text(snapshot?.currentExerciseName ?? "Keep going")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                    metricRow
                }
            } else if let score = snapshot?.readinessScore {
                readinessRing(score: score, size: 58)
                VStack(alignment: .leading, spacing: 5) {
                    header("Readiness", icon: "heart.fill")
                    Text(snapshot?.readinessAction ?? "Open ForgeFit")
                        .font(.title3.bold())
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                    Text(snapshot?.readinessDetail ?? "Check today’s recommendation.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(secondaryText)
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
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    workoutProgressRing(size: 58)
                }
                Text(snapshot?.currentExerciseName ?? "Next set")
                    .font(.headline)
                    .foregroundStyle(primaryText.opacity(0.86))
                    .lineLimit(1)
                metricRow
                Spacer()
                Text(restText)
                    .font(.caption.bold())
                    .foregroundStyle(secondaryText)
            } else if let score = snapshot?.readinessScore {
                HStack {
                    launcherIcon(size: 42)
                    VStack(alignment: .leading, spacing: 2) {
                        header("Today", icon: "heart.fill")
                        Text(snapshot?.readinessAction ?? "Open ForgeFit")
                            .font(.title2.bold())
                            .foregroundStyle(primaryText)
                    }
                    Spacer()
                    readinessRing(score: score, size: 58)
                }
                Text(snapshot?.readinessDetail ?? "Check today’s recommendation.")
                    .font(.headline)
                    .foregroundStyle(primaryText.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
                chipRow(limit: 3)
                Spacer()
                Text("Updated \(snapshot?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "recently")")
                    .font(.caption.bold())
                    .foregroundStyle(secondaryText)
            } else {
                launcherFallback(horizontal: false)
            }
        }
        .padding()
    }

    private func header(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(secondaryText)
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
        .foregroundStyle(secondaryText)
    }

    private func chipRow(limit: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(Array((snapshot?.reasonChips ?? []).prefix(limit)), id: \.self) { chip in
                Text(chip)
                    .font(.caption2.bold())
                    .foregroundStyle(primaryText.opacity(0.82))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(primaryText.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }

    private var setProgressText: String {
        guard let snapshot else { return "Open" }
        return "\(snapshot.completedSets)/\(snapshot.totalSets) sets"
    }

    private var restText: String {
        guard let restEndsAt = snapshot?.restEndsAt else { return "Workout in progress" }
        if restEndsAt > Date() { return "Rest timer running" }
        return "Rest complete"
    }

    private func readinessRing(score: Int, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(primaryText.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(score, 100))) / 100)
                .stroke(isFullColor ? theme.recoveryHigh : .primary, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
        }
        .frame(width: size, height: size)
    }

    private func workoutProgressRing(size: CGFloat) -> some View {
        let total = max(snapshot?.totalSets ?? 0, 1)
        let completed = min(snapshot?.completedSets ?? 0, total)
        return ZStack {
            Circle().stroke(primaryText.opacity(0.18), lineWidth: 5)
            Circle()
                .trim(from: 0, to: CGFloat(completed) / CGFloat(total))
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(completed)")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(primaryText)
        }
        .frame(width: size, height: size)
    }

    private func launcherFallback(horizontal: Bool) -> some View {
        Group {
            if horizontal {
                HStack(spacing: 16) {
                    launcherIcon(size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ForgeFit").font(.title3.bold()).foregroundStyle(primaryText)
                        Text("Open your workouts and recovery.")
                            .font(.subheadline)
                            .foregroundStyle(secondaryText)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    launcherIcon(size: 52)
                    Text("ForgeFit").font(.title2.bold()).foregroundStyle(primaryText)
                    Text("Open your workouts and recovery.")
                        .font(.subheadline)
                        .foregroundStyle(secondaryText)
                }
            }
        }
    }

    /// The Anvil-F, the same mark as the app icon and the launch screen. This
    /// drew a generic SF Symbol dumbbell before, so the one ForgeFit surface a
    /// user sees without opening the app carried none of its branding.
    private func launcherIcon(size: CGFloat) -> some View {
        Image("AnvilFMark")
            // In tinted and vibrant modes the system recolors the whole widget
            // anyway; template rendering keeps the mark's silhouette readable
            // instead of letting it flatten into the tint.
            .renderingMode(isFullColor ? .original : .template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size * 0.88)
            .accessibilityHidden(true)
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
