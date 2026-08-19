import SwiftUI

// MARK: - Concentric day rings

/// Two concentric recovery rings for a calendar day: the OUTER ring is that
/// day's daily readiness, the INNER ring its 7-day trend. Both are colour-coded
/// on the same recovery scale.
///
/// The hard part is the same-colour case — when both scores land in one band
/// (e.g. both green), two touching rings can read as a single thick line. A
/// dedicated dark **moat** ring is painted between them so there is always a
/// base-colour gap separating the two arcs, whatever colour they are and
/// whatever the cell background is.
struct RecoveryDayRings: View {
    /// Daily readiness, 0...1 (outer ring). Nil when that day's acute score
    /// wasn't captured.
    let daily: Double?
    /// 7-day trend, 0...1 (inner ring). Nil until enough history backs it.
    let trend: Double?
    var size: CGFloat = 34
    var lineWidth: CGFloat = 2.5
    /// Clear space between the two rings.
    var moat: CGFloat = 2

    @Environment(\.theme) private var theme

    private var innerSize: CGFloat { size - 2 * (lineWidth + moat) }
    private var bothPresent: Bool { daily != nil && trend != nil }

    var body: some View {
        ZStack {
            // Daily is the outer ring. A single available score always takes the
            // primary (outer) position, so a lone ring never looks like a stray
            // inner circle.
            if let daily {
                ring(progress: daily, diameter: size)
            }
            if bothPresent {
                // Guaranteed dark separator: a base-colour arc in the gap, so
                // two same-colour rings never fuse into one line — and it wins
                // even over a tinted (selected) cell behind it.
                Circle()
                    .stroke(theme.background, lineWidth: moat + 1)
                    .frame(width: (size + innerSize) / 2, height: (size + innerSize) / 2)
            }
            if let trend {
                ring(progress: trend, diameter: bothPresent ? innerSize : size)
            }
        }
        .frame(width: size, height: size)
    }

    private func ring(progress: Double, diameter: CGFloat) -> some View {
        ZStack {
            // Faint track so a low score still reads as a full ring, not a stub.
            Circle().stroke(theme.surfaceHighlight, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(theme.readinessColor(progress), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Selected-day recovery card

/// The selected day's complete Home-metric overview. The shared tile language
/// keeps historical readings visually aligned with today without implying
/// that these static calendar values are navigation controls.
struct RecoveryDaySummaryCard: View {
    let snapshot: RecoverySnapshot?
    let selectedDay: Date
    let healthMetrics: [RecoveryEngine.DailyHealthMetric]
    let isLoadingHealth: Bool
    @Environment(\.theme) private var theme

    private let calendar = Calendar.current

    private var selectedMetric: RecoveryEngine.DailyHealthMetric? {
        CalendarDayHealthSupport.metric(for: selectedDay, in: healthMetrics, calendar: calendar)
    }

    private var healthAssessment: HealthRangeAssessment {
        CalendarDayHealthSupport.assessment(for: selectedDay, in: healthMetrics, calendar: calendar)
    }

    var body: some View {
        VStack(spacing: Space.md) {
            HStack(alignment: .top, spacing: Space.md) {
                recoveryTile
                trendRecoveryTile
            }
            HStack(alignment: .top, spacing: Space.md) {
                sleepTile
                StrainSummaryTile(
                    score: snapshot?.strain,
                    usualRange: snapshot?.strainTargetRange,
                    isLoading: false,
                    isRefreshing: false,
                    showsDisclosure: false,
                    missingLabel: snapshot?.strain == nil ? "No data" : nil
                )
                .accessibilityIdentifier("recovery-summary-strain")
            }
            healthTile
        }
    }

    private var recoveryTile: some View {
        scoreTile(
            title: "Recovery",
            systemImage: "heart.text.square.fill",
            value: snapshot?.daily,
            caption: "That day",
            identifier: "recovery-summary-recovery"
        )
    }

    private var trendRecoveryTile: some View {
        scoreTile(
            title: "Trend recovery",
            systemImage: "chart.line.uptrend.xyaxis",
            value: snapshot?.trend,
            caption: "7-day trend",
            identifier: "recovery-summary-trend-recovery"
        )
    }

    private func scoreTile(
        title: String,
        systemImage: String,
        value: Double?,
        caption: String,
        identifier: String
    ) -> some View {
        MetricSummaryTile(
            title: title,
            systemImage: systemImage,
            value: value.map { "\(Int(($0 * 100).rounded()))" } ?? "No data",
            caption: caption,
            tint: value.map(theme.readinessColor) ?? theme.textTertiary,
            progress: value,
            showsDisclosure: false
        )
        .accessibilityIdentifier(identifier)
    }

    private var sleepTile: some View {
        let metric = selectedMetric
        let progress = SleepMetricPresentation.progress(for: metric)
        let looksPartial = metric?.sleepLikelyPartial == true && metric?.sleepUserCorrected == false
        return MetricSummaryTile(
            title: "Sleep",
            systemImage: "moon.zzz.fill",
            value: isLoadingHealth && metric == nil ? "Loading" : SleepMetricPresentation.value(for: metric),
            caption: isLoadingHealth && metric == nil ? "Checking Apple Health" : SleepMetricPresentation.caption(for: metric),
            tint: progress == nil ? theme.textTertiary : looksPartial ? theme.warmup : theme.zone2,
            progress: progress,
            isLoading: isLoadingHealth && metric == nil,
            showsDisclosure: false
        )
        .accessibilityIdentifier("calendar-summary-sleep")
    }

    private var healthTile: some View {
        let assessment = healthAssessment
        let loading = isLoadingHealth && selectedMetric == nil
        return MetricSummaryTile(
            title: "Vitals",
            systemImage: "waveform.path.ecg.rectangle.fill",
            value: loading ? "Loading" : assessment.headline,
            caption: loading ? "Checking Apple Health" : assessment.caption,
            tint: assessment.evaluatedCount == 0
                ? theme.textTertiary
                : assessment.adverseCount > 0
                    ? theme.recoveryLow
                    : assessment.favorableCount > 0 ? theme.success : theme.zone2,
            isLoading: loading,
            showsDisclosure: false
        )
        .accessibilityIdentifier("calendar-summary-health")
    }
}
