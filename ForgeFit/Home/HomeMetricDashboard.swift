import SwiftUI

struct HomeMetricGrid: View {
    @Environment(\.theme) private var theme

    let recovery: RecoveryEngine.Report
    let strain: DailyStrainEngine.Report
    let sleep: RecoveryEngine.DailyHealthMetric?
    let health: HealthRangeAssessment
    let isLoading: Bool

    private let columns = [
        GridItem(.flexible(), spacing: Space.md),
        GridItem(.flexible(), spacing: Space.md),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Space.md) {
            NavigationLink(value: HomeRoute.recovery) {
                recoveryTile
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-recovery-card")

            NavigationLink(value: HomeRoute.sleep) {
                sleepTile
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-sleep-card")

            NavigationLink(value: HomeRoute.strain) {
                strainTile
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("daily-strain-card")

            NavigationLink(value: HomeRoute.health) {
                healthTile
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home-health-card")
        }
        .accessibilityIdentifier("home-metric-grid")
    }

    private var recoveryTile: some View {
        if isLoading {
            return loadingTile(title: "Recovery", systemImage: "heart.text.square.fill")
        }
        let isBuilding = !recovery.baselineReady
        let value = isBuilding ? "Building" : "\(Int((recovery.displayScore * 100).rounded()))"
        let suffix = isBuilding ? nil : "%"
        let caption = isBuilding ? "Personal baseline in progress" : recovery.action.title
        return HomeMetricTile(
            title: "Recovery",
            systemImage: "heart.text.square.fill",
            value: value,
            suffix: suffix,
            caption: caption,
            tint: isBuilding ? theme.textTertiary : theme.readinessColor(recovery.displayScore),
            progress: isBuilding ? nil : recovery.displayScore
        )
    }

    private var sleepTile: some View {
        if isLoading {
            return loadingTile(title: "Sleep", systemImage: "moon.zzz.fill")
        }
        let progress: Double? = {
            guard let sleep, sleep.sleepOverrideStatus != .notTracked,
                  let minutes = sleep.sleepTotalMinutes, sleep.sleepNeedMinutes > 0 else { return nil }
            return min(1, max(0, Double(minutes) / Double(sleep.sleepNeedMinutes)))
        }()
        let tint = sleep?.sleepLikelyPartial == true && sleep?.sleepUserCorrected == false
            ? theme.warmup : theme.zone2
        return HomeMetricTile(
            title: "Sleep",
            systemImage: "moon.zzz.fill",
            value: SleepMetricPresentation.value(for: sleep),
            caption: SleepMetricPresentation.caption(for: sleep),
            tint: tint,
            progress: progress
        )
    }

    private var strainTile: some View {
        if isLoading {
            return loadingTile(title: "Strain", systemImage: "flame.fill")
        }
        let value = strain.score?.formatted(.number.precision(.fractionLength(1))) ?? "Building"
        let suffix = strain.score == nil ? nil : "/10"
        return HomeMetricTile(
            title: "Strain",
            systemImage: "flame.fill",
            value: value,
            suffix: suffix,
            caption: strainCaption,
            tint: strain.status == .aboveTarget ? theme.warmup : theme.secondaryAccent,
            progress: strain.score.map { min(1, max(0, $0 / 10)) }
        )
    }

    private var healthTile: some View {
        if isLoading {
            return loadingTile(title: "Health", systemImage: "waveform.path.ecg.rectangle.fill")
        }
        let tint = health.evaluatedCount == 0
            ? theme.textTertiary
            : health.outsideRangeCount > 0 ? theme.recoveryLow : theme.success
        return HomeMetricTile(
            title: "Health",
            systemImage: "waveform.path.ecg.rectangle.fill",
            value: health.headline,
            caption: health.caption,
            tint: tint,
            progress: health.evaluatedCount > 0
                ? Double(health.evaluatedCount - health.outsideRangeCount) / Double(health.evaluatedCount)
                : nil
        )
    }

    private func loadingTile(title: String, systemImage: String) -> HomeMetricTile {
        HomeMetricTile(
            title: title,
            systemImage: systemImage,
            value: "Loading",
            caption: "Syncing today's data",
            tint: theme.textTertiary,
            isLoading: true
        )
    }

    private var strainCaption: String {
        guard let score = strain.score else { return "7 days builds your target" }
        switch strain.status {
        case .building: return "Building movement baseline"
        case .targetBuilding: return "Recovery target building"
        case .belowTarget:
            guard let lower = strain.targetRange?.lowerBound else { return "Below today's target" }
            return "\(max(0, lower - score).formatted(.number.precision(.fractionLength(1)))) to target"
        case .inTarget: return "Today's target reached"
        case .aboveTarget: return "Above today's target"
        }
    }
}

private struct HomeMetricTile: View {
    @Environment(\.theme) private var theme

    let title: String
    let systemImage: String
    let value: String
    var suffix: String? = nil
    let caption: String
    let tint: Color
    var progress: Double? = nil
    var isLoading = false

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(tint)
                    }
                    Text(value)
                        .font(.system(size: value.count > 8 ? 21 : 28, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let suffix {
                        Text(suffix)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .frame(height: 34, alignment: .leading)

                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.surfaceElevated)
                        if let progress {
                            Capsule()
                                .fill(tint)
                                .frame(width: max(5, proxy.size.width * min(1, max(0, progress))))
                        }
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)\(suffix.map { " \($0)" } ?? ""), \(caption)")
        .accessibilityHint("Opens \(title) details")
    }
}

struct TrainingLoadGauge: View {
    @Environment(\.theme) private var theme
    let comparison: TrainingLoadComparison

    /// Tone grades with the size of the deviation — still descriptive, but a
    /// week 50%+ over baseline should not read the same as +8%.
    private var tint: Color {
        guard let ratio = comparison.ratio else { return theme.textTertiary }
        if ratio < 0.95 { return theme.textSecondary }
        if ratio <= 1.05 { return theme.success }
        if ratio <= 1.5 { return theme.warmup }
        return theme.danger
    }

    private var label: String {
        switch comparison.state {
        case .building:
            return "\(comparison.baselineDaysAvailable)/28 prior days"
        case .noRecentLoad:
            return "No recent baseline"
        case .sparseBaseline:
            return "Baseline too light"
        case .ready:
            guard let ratio = comparison.ratio else { return "Baseline unavailable" }
            let percent = Int((abs(ratio - 1) * 100).rounded())
            if percent <= 5 { return "Near baseline" }
            return "\(percent)% \(ratio > 1 ? "above" : "below")"
        }
    }

    private var detail: String {
        switch comparison.state {
        case .building:
            let days = comparison.baselineDaysRemaining
            return "Needs \(days) more prior day\(days == 1 ? "" : "s") before comparing the last 7 days."
        case .noRecentLoad:
            return "No logged load in the prior 4 weeks, so ForgeFit does not show a percentage."
        case .sparseBaseline:
            return "The prior 4 weeks carry too little load for a percentage against them to mean anything."
        case .ready:
            let estimated = comparison.estimatedEffortSessionCount
            if estimated > 0 {
                return "Set-by-set effort + zone-weighted cardio · effort estimated for \(estimated) session\(estimated == 1 ? "" : "s") · descriptive only"
            }
            return "Set-by-set effort + zone-weighted cardio · descriptive only"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comparison.state == .building ? "Training load baseline" : "Last 7 days vs prior 4 weeks")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Text(label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceElevated)
                    if comparison.state == .building {
                        let progressWidth = proxy.size.width * Double(comparison.baselineDaysAvailable) / 28
                        Capsule()
                            .fill(tint)
                            .frame(width: comparison.baselineDaysAvailable == 0 ? 0 : max(6, progressWidth))
                    } else if let ratio = comparison.ratio {
                        let baselineX = proxy.size.width / 2
                        let currentX = proxy.size.width * min(1, max(0, ratio / 2))
                        Capsule()
                            .fill(tint)
                            .frame(width: max(3, abs(currentX - baselineX)))
                            .offset(x: min(currentX, baselineX))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(theme.textTertiary)
                            .frame(width: 2, height: 10)
                            .position(x: baselineX, y: proxy.size.height / 2)
                    }
                }
            }
            .frame(height: 6)

            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Training load, \(label). \(detail)")
    }
}
