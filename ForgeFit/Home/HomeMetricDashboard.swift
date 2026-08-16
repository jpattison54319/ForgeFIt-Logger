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
        let score: Double?
        let baselineReady: Bool
        let isDailyScore: Bool
        let actionTitle: String
        switch source {
        case .loading:
            return loadingTile(title: "Recovery", systemImage: "heart.text.square.fill")
        case .cached(let snapshot, let cache):
            score = cache.recoveryDisplayScore
            baselineReady = cache.baselineReady
            isDailyScore = snapshot.daily != nil
            let action = RecoveryEngine.Action(rawValue: cache.actionRaw)?.title ?? ""
            actionTitle = snapshot.daily == nil && snapshot.trend != nil
                ? "7-day trend · \(action)"
                : action
        case .live:
            score = recovery.displayScore
            baselineReady = recovery.baselineReady
            isDailyScore = recovery.recovery.daily.state.value != nil
            actionTitle = recovery.recovery.daily.state.value == nil
                && recovery.recovery.systemic.state.value != nil
                ? "7-day trend · \(recovery.action.title)"
                : recovery.action.title
        }
        let isBuilding = !baselineReady || score == nil
        let resolvedScore = score ?? 0
        return MetricSummaryTile(
            title: "Recovery",
            systemImage: "heart.text.square.fill",
            value: isBuilding ? "Building" : "\(Int((resolvedScore * 100).rounded()))",
            suffix: nil,
            caption: isBuilding ? "Personal baseline in progress" : actionTitle,
            tint: isBuilding || !isDailyScore ? theme.textTertiary : theme.readinessColor(resolvedScore),
            progress: isBuilding || !isDailyScore ? nil : resolvedScore,
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
        return MetricSummaryTile(
            title: "Sleep",
            systemImage: "moon.zzz.fill",
            value: value,
            caption: caption,
            // No progress means no measurement to plot — an untracked night, a
            // night with no sleep recorded, or Health not connected at all.
            // Those read as "No data" / "Not tracked", and tinting them like a
            // reading made the absence of data the loudest thing on Home.
            tint: progress == nil
                ? theme.textTertiary
                : looksPartial ? theme.warmup : theme.zone2,
            progress: progress,
            isRefreshing: isRefreshing
        )
    }

    private var strainTile: some View {
        let score: Double?
        let target: ClosedRange<Double>?
        let isLoading: Bool
        switch source {
        case .loading:
            score = nil
            target = nil
            isLoading = true
        case .cached(let snapshot, _):
            score = snapshot.strain
            target = snapshot.strainTargetRange
            isLoading = false
        case .live:
            score = strain.score
            target = strain.targetRange
            isLoading = false
        }
        return StrainSummaryTile(
            score: score,
            usualRange: target,
            isLoading: isLoading,
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
        return MetricSummaryTile(
            title: "Health",
            systemImage: "waveform.path.ecg.rectangle.fill",
            value: headline,
            caption: caption,
            tint: evaluated == 0
                ? theme.textTertiary
                : outside > 0 ? theme.recoveryLow : theme.success,
            // Health is a set of readings, not a combined score. A progress
            // fill made the in-range fraction look like another health grade.
            progress: nil,
            isRefreshing: isRefreshing
        )
    }

    private func loadingTile(title: String, systemImage: String) -> MetricSummaryTile {
        MetricSummaryTile(
            title: title,
            systemImage: systemImage,
            value: "Loading",
            caption: "Syncing today's data",
            tint: theme.textTertiary,
            isLoading: true
        )
    }

}

struct DailyStrainGaugePresentation: Equatable {
    enum Band: Equatable {
        case muchLower
        case belowUsual
        case usual
        case aboveUsual
        case muchHigher
        case collectingBaseline
        case rangePending

        var title: String {
            switch self {
            case .muchLower: "Far below usual"
            case .belowUsual: "Below usual"
            case .usual: "In your usual range"
            case .aboveUsual: "Above usual"
            case .muchHigher: "Far above usual"
            case .collectingBaseline: "Collecting baseline"
            case .rangePending: "More history needed"
            }
        }
    }

    let band: Band
    /// Position around the semicircle: 0 is the far-left low end, 0.5 is the
    /// top-center usual baseline, and 1 is the far-right high end.
    let position: Double?

    init(score: Double?, usualRange: ClosedRange<Double>?) {
        guard let score else {
            band = .collectingBaseline
            position = nil
            return
        }
        guard let usualRange else {
            band = .rangePending
            position = nil
            return
        }

        let clampedScore = min(10, max(0, score))
        let lower = min(10, max(0, usualRange.lowerBound))
        let upper = min(10, max(lower, usualRange.upperBound))
        let farLowerBoundary = lower / 2
        let farUpperBoundary = upper + (10 - upper) / 2

        switch clampedScore {
        case ..<farLowerBoundary:
            band = .muchLower
            position = Self.interpolate(clampedScore, from: 0...farLowerBoundary, to: 0...0.2)
        case ..<lower:
            band = .belowUsual
            position = Self.interpolate(clampedScore, from: farLowerBoundary...lower, to: 0.2...0.4)
        case ...upper:
            band = .usual
            position = Self.interpolate(clampedScore, from: lower...upper, to: 0.4...0.6)
        case ...farUpperBoundary:
            band = .aboveUsual
            position = Self.interpolate(clampedScore, from: upper...farUpperBoundary, to: 0.6...0.8)
        default:
            band = .muchHigher
            position = Self.interpolate(clampedScore, from: farUpperBoundary...10, to: 0.8...1)
        }
    }

    private static func interpolate(
        _ value: Double,
        from source: ClosedRange<Double>,
        to destination: ClosedRange<Double>
    ) -> Double {
        guard source.upperBound > source.lowerBound else {
            return (destination.lowerBound + destination.upperBound) / 2
        }
        let progress = min(1, max(0, (value - source.lowerBound) / (source.upperBound - source.lowerBound)))
        return destination.lowerBound + progress * (destination.upperBound - destination.lowerBound)
    }
}

struct StrainSummaryTile: View {
    @Environment(\.theme) private var theme

    let score: Double?
    let usualRange: ClosedRange<Double>?
    let isLoading: Bool
    let isRefreshing: Bool
    var showsDisclosure = true
    var missingLabel: String? = nil

    private var presentation: DailyStrainGaugePresentation {
        DailyStrainGaugePresentation(score: score, usualRange: usualRange)
    }

    private var tint: Color {
        switch presentation.band {
        case .usual: theme.success
        case .aboveUsual, .muchHigher: theme.warmup
        case .muchLower, .belowUsual: theme.zone2
        case .collectingBaseline, .rangePending: theme.textTertiary
        }
    }

    var body: some View {
        Card(padding: Space.md) {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                    Text("Strain")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
                        .textCase(.uppercase)
                    Spacer(minLength: 0)
                    if isRefreshing || isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(theme.textTertiary)
                    }
                    if showsDisclosure {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                StrainSemicircleGauge(
                    position: presentation.position,
                    label: isLoading ? "Loading today" : missingLabel ?? presentation.band.title,
                    tint: tint
                )
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(showsDisclosure ? "Opens Strain details" : "")
    }

    private var accessibilityLabel: String {
        guard !isLoading else { return "Strain, loading today's data" }
        guard let score else {
            return missingLabel.map { "Strain, \($0.lowercased())" }
                ?? "Strain, collecting baseline. Your personal score needs more comparable history."
        }
        let scoreText = score.formatted(.number.precision(.fractionLength(1)))
        guard let usualRange else {
            return "Strain, score \(scoreText) out of 10. More history needed to show your usual range."
        }
        let lower = usualRange.lowerBound.formatted(.number.precision(.fractionLength(1)))
        let upper = usualRange.upperBound.formatted(.number.precision(.fractionLength(1)))
        return "Strain, \(presentation.band.title), score \(scoreText) out of 10, usual range \(lower) to \(upper)"
    }
}

struct StrainSemicircleGauge: View {
    @Environment(\.theme) private var theme

    let position: Double?
    let label: String
    let tint: Color
    var showsDirectionLabels = false

    var body: some View {
        GeometryReader { proxy in
            let lineWidth = 8.0
            let directionLabelHeight = showsDirectionLabels ? 17.0 : 0
            let center = CGPoint(
                x: proxy.size.width / 2,
                y: proxy.size.height - directionLabelHeight - lineWidth / 2
            )
            let radius = min(
                proxy.size.width / 2 - lineWidth / 2,
                center.y - lineWidth / 2
            )

            ZStack {
                gaugeSegments(
                    center: center,
                    radius: radius,
                    lineWidth: lineWidth
                )

                marker(
                    at: 0.5,
                    center: center,
                    radius: radius,
                    width: 2,
                    height: 10,
                    color: theme.textPrimary.opacity(0.45)
                )

                if let position {
                    let clamped = min(1, max(0, position))
                    marker(
                        at: clamped,
                        center: center,
                        radius: radius,
                        width: 4,
                        height: 18,
                        color: tint
                    )
                }

                Text(label)
                    .font(.system(size: label.count > 11 ? 14 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(position == nil ? theme.textTertiary : tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .position(x: center.x, y: center.y - radius * 0.34)

                if showsDirectionLabels {
                    HStack {
                        Text("Lower")
                        Spacer()
                        Text("Higher")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .position(
                        x: proxy.size.width / 2,
                        y: proxy.size.height - 5
                    )
                }
            }
            .animation(Motion.stateChange, value: position)
            .animation(Motion.stateChange, value: label)
        }
        .frame(height: 76)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func gaugeSegments(
        center: CGPoint,
        radius: Double,
        lineWidth: Double
    ) -> some View {
        ForEach(0..<5, id: \.self) { segment in
            StrainSemicircleArc(center: center, radius: radius)
                .trim(
                    from: Double(segment) / 5 + 0.007,
                    to: Double(segment + 1) / 5 - 0.007
                )
                .stroke(
                    segment == 2 ? theme.success.opacity(0.22) : theme.surfaceElevated,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
        }
    }

    private func marker(
        at progress: Double,
        center: CGPoint,
        radius: Double,
        width: Double,
        height: Double,
        color: Color
    ) -> some View {
        let clamped = min(1, max(0, progress))
        let angle = .pi + .pi * clamped
        return Capsule()
            .fill(color)
            .frame(width: width, height: height)
            .rotationEffect(.radians(angle - 1.5 * .pi))
            .position(point(on: center, radius: radius, progress: clamped))
    }

    private func point(on center: CGPoint, radius: Double, progress: Double) -> CGPoint {
        let angle = .pi + .pi * progress
        return CGPoint(
            x: center.x + radius * cos(angle),
            y: center.y + radius * sin(angle)
        )
    }
}

private struct StrainSemicircleArc: Shape {
    var center: CGPoint?
    var radius: Double?

    func path(in rect: CGRect) -> Path {
        let lineAllowance = 4.0
        let resolvedCenter = center ?? CGPoint(x: rect.midX, y: rect.maxY - 2)
        let resolvedRadius = radius ?? min(rect.width / 2 - lineAllowance, rect.height - lineAllowance)
        var path = Path()
        path.addArc(
            center: resolvedCenter,
            radius: max(0, resolvedRadius),
            startAngle: .degrees(180),
            endAngle: .degrees(360),
            clockwise: false
        )
        return path
    }
}

struct MetricSummaryTile: View {
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
    var showsDisclosure = true

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
                    if showsDisclosure {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
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

                if let progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.surfaceElevated)
                            Capsule()
                                .fill(tint)
                                .frame(width: max(5, proxy.size.width * min(1, max(0, progress))))
                        }
                        .animation(Motion.stateChange, value: progress)
                    }
                    .frame(height: 5)
                } else {
                    Color.clear.frame(height: 5)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)\(suffix.map { " \($0)" } ?? ""), \(caption)\(isRefreshing ? ", updating" : "")")
        .accessibilityHint(showsDisclosure ? "Opens \(title) details" : "")
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
            return "No usable load exists in the available prior complete weeks, so ForgeFit does not show a percentage."
        case .sparseBaseline:
            return "The prior complete weeks have a zero median, so a percentage would be misleading."
        case .ready:
            return comparison.estimatedEffortSessionCount > 0
                ? "Session CR10 + estimated components · descriptive only"
                : "Duration × whole-session CR10 · descriptive only"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(comparison.state == .building ? "Training load baseline" : "Last 7 days vs prior weeks")
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

            if comparison.state != .ready || FeatureFlags.trainingLoadMethodDetail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home-training-load-detail")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        if comparison.state == .ready, !FeatureFlags.trainingLoadMethodDetail {
            return "Training load, \(label)."
        }
        return "Training load, \(label). \(detail)"
    }
}
