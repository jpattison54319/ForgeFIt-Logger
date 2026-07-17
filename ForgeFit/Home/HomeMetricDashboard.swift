import SwiftUI

/// What backs the Home dashboard right now.
///
/// - `live`: this launch's HealthKit refresh has landed; the engine reports
///   drive everything.
/// - `cached`: cold launch, refresh still in flight, but TODAY already has a
///   recorded render — paint those numbers instantly instead of a loader.
/// - `loading`: first open of the day (or first launch ever). A new day never
///   shows an older day's numbers, so there is nothing honest to paint yet.
enum HomeDashboardSource: Equatable {
    case loading
    case cached(RecoverySnapshot, HomeDashboardCache)
    case live
}

struct HomeMetricGrid: View {
    @Environment(\.theme) private var theme

    let recovery: RecoveryEngine.Report
    let strain: DailyStrainEngine.Report
    let sleep: RecoveryEngine.DailyHealthMetric?
    let health: HealthRangeAssessment
    let source: HomeDashboardSource
    /// A HealthKit re-query is in flight (cold launch, foreground, or pull to
    /// refresh): every tile keeps its current numbers and shows a small
    /// activity indicator instead of blanking.
    let isRefreshing: Bool

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
        let score: Double
        let baselineReady: Bool
        let actionTitle: String
        switch source {
        case .loading:
            return loadingTile(title: "Recovery", systemImage: "heart.text.square.fill")
        case .cached(_, let cache):
            score = cache.recoveryDisplayScore
            baselineReady = cache.baselineReady
            actionTitle = RecoveryEngine.Action(rawValue: cache.actionRaw)?.title ?? ""
        case .live:
            score = recovery.displayScore
            baselineReady = recovery.baselineReady
            actionTitle = recovery.action.title
        }
        let isBuilding = !baselineReady
        return HomeMetricTile(
            title: "Recovery",
            systemImage: "heart.text.square.fill",
            value: isBuilding ? "Building" : "\(Int((score * 100).rounded()))",
            suffix: isBuilding ? nil : "%",
            caption: isBuilding ? "Personal baseline in progress" : actionTitle,
            tint: isBuilding ? theme.textTertiary : theme.readinessColor(score),
            progress: isBuilding ? nil : score,
            isRefreshing: isRefreshing
        )
    }

    private var sleepTile: some View {
        let value: String
        let caption: String
        let progress: Double?
        let looksPartial: Bool
        switch source {
        case .loading:
            return loadingTile(title: "Sleep", systemImage: "moon.zzz.fill")
        case .cached(_, let cache):
            value = cache.sleepValue
            caption = cache.sleepCaption
            progress = cache.sleepProgress
            looksPartial = cache.sleepLooksPartial
        case .live:
            value = SleepMetricPresentation.value(for: sleep)
            caption = SleepMetricPresentation.caption(for: sleep)
            progress = SleepMetricPresentation.progress(for: sleep)
            looksPartial = sleep?.sleepLikelyPartial == true && sleep?.sleepUserCorrected == false
        }
        return HomeMetricTile(
            title: "Sleep",
            systemImage: "moon.zzz.fill",
            value: value,
            caption: caption,
            tint: looksPartial ? theme.warmup : theme.zone2,
            progress: progress,
            isRefreshing: isRefreshing
        )
    }

    private var strainTile: some View {
        let score: Double?
        let target: ClosedRange<Double>?
        switch source {
        case .loading:
            return loadingTile(title: "Strain", systemImage: "flame.fill")
        case .cached(let snapshot, _):
            score = snapshot.strain
            target = snapshot.strainTargetRange
        case .live:
            score = strain.score
            target = strain.targetRange
        }
        let status = DailyStrainEngine.Report.status(score: score, targetRange: target)
        return HomeMetricTile(
            title: "Strain",
            systemImage: "flame.fill",
            value: score?.formatted(.number.precision(.fractionLength(1))) ?? "Building",
            suffix: score == nil ? nil : "/10",
            caption: strainCaption(score: score, target: target, status: status),
            tint: status == .aboveTarget ? theme.warmup : theme.secondaryAccent,
            progress: score.map { min(1, max(0, $0 / 10)) },
            isRefreshing: isRefreshing
        )
    }

    private var healthTile: some View {
        let headline: String
        let caption: String
        let evaluated: Int
        let outside: Int
        switch source {
        case .loading:
            return loadingTile(title: "Health", systemImage: "waveform.path.ecg.rectangle.fill")
        case .cached(_, let cache):
            headline = cache.healthHeadline
            caption = cache.healthCaption
            evaluated = cache.healthEvaluatedCount
            outside = cache.healthOutsideRangeCount
        case .live:
            headline = health.headline
            caption = health.caption
            evaluated = health.evaluatedCount
            outside = health.outsideRangeCount
        }
        return HomeMetricTile(
            title: "Health",
            systemImage: "waveform.path.ecg.rectangle.fill",
            value: headline,
            caption: caption,
            tint: evaluated == 0
                ? theme.textTertiary
                : outside > 0 ? theme.recoveryLow : theme.success,
            progress: evaluated > 0 ? Double(evaluated - outside) / Double(evaluated) : nil,
            isRefreshing: isRefreshing
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

    private func strainCaption(
        score: Double?,
        target: ClosedRange<Double>?,
        status: DailyStrainEngine.Report.Status
    ) -> String {
        guard let score else { return "7 days builds your target" }
        switch status {
        case .building: return "Building movement baseline"
        case .targetBuilding: return "Recovery target building"
        case .belowTarget:
            guard let lower = target?.lowerBound else { return "Below today's target" }
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
    /// Fresh data is being fetched behind the numbers currently shown —
    /// distinct from `isLoading`, which means there is nothing to show yet.
    var isRefreshing = false

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
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(theme.textTertiary)
                    }
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
                        .contentTransition(.numericText())
                        .animation(Motion.stateChange, value: value)
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
                    .animation(Motion.stateChange, value: progress)
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)\(suffix.map { " \($0)" } ?? ""), \(caption)\(isRefreshing ? ", updating" : "")")
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
                    .contentTransition(.opacity)
                    .animation(Motion.stateChange, value: label)
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
                .animation(Motion.stateChange, value: comparison.ratio)
                .animation(Motion.stateChange, value: comparison.baselineDaysAvailable)
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
