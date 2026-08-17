import Charts
import SwiftData
import SwiftUI

struct StrainDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let report: DailyStrainEngine.Report
    @State private var selectedTab: MetricDetailTab = .today
    @State private var showingInfo = false
    @State private var snapshots = RecoverySnapshotStore.shared
    @State private var selectedTrendDate: Date?

    private struct TrendPoint: Identifiable {
        var id: Date { date }
        let date: Date
        let score: Double
        let target: ClosedRange<Double>?
    }

    private var trendPoints: [TrendPoint] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        return snapshots.snapshots
            .compactMap { date, snapshot -> TrendPoint? in
                guard date >= cutoff, let score = snapshot.strain else { return nil }
                return TrendPoint(date: date, score: score, target: snapshot.strainTargetRange)
            }
            .sorted { $0.date < $1.date }
    }

    var body: some View {
        MetricDetailScaffold(title: "Strain", selectedTab: $selectedTab) {
            switch selectedTab {
            case .today:
                todayContent
            case .trends:
                trendsContent
            }
        }
        .refreshable { await AppRefresh.run(in: modelContext) }
        .sheet(isPresented: $showingInfo) {
            DailyStrainInfoSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var todayContent: some View {
        if let score = report.score {
            strainSummary(score)
            scoreBreakdown
        } else {
            MetricEmptyCard(
                title: "Collecting baseline",
                message: "Fourteen comparable days unlock a personal score. Rate the whole workout for the best training estimate; otherwise ForgeFit uses its logged components.",
                systemImage: "chart.line.uptrend.xyaxis"
            )
        }

        MetricInfoLink(title: "How strain is calculated") {
            showingInfo = true
        }
        .accessibilityIdentifier("daily-strain-info")
    }

    @ViewBuilder
    private var trendsContent: some View {
        if trendPoints.count >= 2 {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Strain and usual range")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                            Text("Last 30 days")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text("Avg \(averageStrain.formatted(.number.precision(.fractionLength(1))))")
                            .font(.tag)
                            .foregroundStyle(theme.textSecondary)
                    }
                    strainTrendChart
                    HStack(spacing: Space.lg) {
                        Label("Daily strain", systemImage: "line.diagonal")
                            .foregroundStyle(theme.secondaryAccentForeground)
                        Label("Usual range", systemImage: "rectangle.fill")
                            .foregroundStyle(theme.accent.opacity(0.55))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    Text("The shaded range is descriptive history. It is not an optimized target or injury-risk threshold.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                HStack {
                    trendStat("Tracked days", "\(trendPoints.count)")
                    trendStat("Within usual", "\(daysInTarget)")
                    trendStat("Average", averageStrain.formatted(.number.precision(.fractionLength(1))))
                }
            }
        } else {
            MetricEmptyCard(
                title: "Strain trend is building",
                message: "Keep Apple Health connected and log workouts to compare each day with your usual range.",
                systemImage: "chart.xyaxis.line"
            )
        }
    }

    private func strainSummary(_ score: Double) -> some View {
        let presentation = DailyStrainGaugePresentation(
            score: score,
            usualRange: report.targetRange
        )
        return Card {
            VStack(spacing: Space.md) {
                StrainSemicircleGauge(
                    position: presentation.position,
                    label: presentation.band.title,
                    tint: strainTint,
                    showsDirectionLabels: true
                )
                .frame(height: 92)

                HStack(spacing: Space.lg) {
                    summaryMetric(
                        label: "Today",
                        value: "\(score.formatted(.number.precision(.fractionLength(1)))) / 10",
                        valueColor: strainTint,
                        isTrailing: false
                    )

                    Divider()
                        .overlay(theme.separator)
                        .frame(height: 34)

                    if let range = report.targetRange {
                        summaryMetric(
                            label: "Usual range",
                            value: "\(formatted(range.lowerBound))–\(formatted(range.upperBound))",
                            valueColor: theme.textPrimary,
                            isTrailing: true
                        )
                    } else {
                        summaryMetric(
                            label: "Usual range",
                            value: "More history needed",
                            valueColor: theme.textTertiary,
                            isTrailing: true
                        )
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(strainSummaryAccessibility(score, presentation: presentation))
        .accessibilityIdentifier("strain-today-summary")
    }

    private func summaryMetric(
        label: String,
        value: String,
        valueColor: Color,
        isTrailing: Bool
    ) -> some View {
        VStack(alignment: isTrailing ? .trailing : .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textTertiary)
                .textCase(.uppercase)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(
            maxWidth: .infinity,
            alignment: isTrailing ? .trailing : .leading
        )
    }

    private var scoreBreakdown: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Score breakdown")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                MetricReadingRow(
                    title: "Movement · 35%",
                    value: percentileText(report.movementRatio),
                    systemImage: "shoeprints.fill",
                    detail: report.steps.map { "\($0.formatted()) steps by this time" }
                        ?? "Same-time steps unavailable",
                    tint: theme.zone2
                )
                Divider().overlay(theme.separator)
                MetricReadingRow(
                    title: "Training · 65%",
                    value: percentileText(report.workoutRatio),
                    systemImage: "dumbbell.fill",
                    detail: trainingDetail,
                    tint: theme.accent
                )
            }
        }
    }

    private var trainingDetail: String {
        guard report.workoutRatio != nil else {
            return "Needs comparable workout history"
        }
        guard report.workoutLoad > 0 else { return "No training load today" }
        let load = Int(report.workoutLoad.rounded()).formatted()
        let detail = report.workoutMinutes > 0
            ? "\(load) load · \(report.workoutMinutes) min"
            : "\(load) load"
        return report.workoutLoadWasEstimated ? "Estimated · \(detail)" : detail
    }

    private func percentileText(_ ratio: Double?) -> String {
        guard let ratio else { return "Unavailable" }
        return "Percentile \(Int((ratio * 100).rounded()))"
    }

    private var strainTrendChart: some View {
        Chart(trendPoints) { point in
            if let target = point.target {
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Usual low", target.lowerBound),
                    yEnd: .value("Usual high", target.upperBound)
                )
                .foregroundStyle(theme.accent.opacity(0.13))
            }
            LineMark(x: .value("Date", point.date), y: .value("Strain", point.score))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(theme.secondaryAccentForeground)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            PointMark(x: .value("Date", point.date), y: .value("Strain", point.score))
                .foregroundStyle(theme.secondaryAccentForeground)
                .symbolSize(20)
            if selectedTrendDate != nil,
               point.id == selectedTrendPoint?.id {
                RuleMark(x: .value("Selected date", point.date))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: point.date.formatted(date: .abbreviated, time: .omitted),
                            lines: [("Strain", "\(point.score.formatted(.number.precision(.fractionLength(1)))) / 10")]
                        )
                    }
            }
        }
        .chartYScale(domain: 0...10)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.35))
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 2, 4, 6, 8, 10]) { _ in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                AxisValueLabel().foregroundStyle(theme.textTertiary)
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            Text("Strain (/10)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .pressHoldChartXSelection(value: $selectedTrendDate)
        .frame(height: 190)
        .accessibilityLabel("Daily strain over the last 30 days")
        .accessibilityValue("Average \(averageStrain.formatted(.number.precision(.fractionLength(1)))); \(daysInTarget) days within the usual range.")
    }

    private var selectedTrendPoint: TrendPoint? {
        guard let selectedTrendDate else { return nil }
        return trendPoints.min {
            abs($0.date.timeIntervalSince(selectedTrendDate)) < abs($1.date.timeIntervalSince(selectedTrendDate))
        }
    }

    private func trendStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.statValue)
                .foregroundStyle(theme.textPrimary)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var averageStrain: Double {
        guard !trendPoints.isEmpty else { return 0 }
        return trendPoints.map(\.score).reduce(0, +) / Double(trendPoints.count)
    }

    private var daysInTarget: Int {
        trendPoints.count { point in
            point.target?.contains(point.score) == true
        }
    }

    private var strainTint: Color {
        let band = DailyStrainGaugePresentation(
            score: report.score,
            usualRange: report.targetRange
        ).band
        return switch band {
        case .usual: theme.success
        case .aboveUsual, .muchHigher: theme.warmup
        case .belowUsual, .muchLower: theme.zone2
        case .collectingBaseline, .rangePending: theme.textTertiary
        }
    }

    private func strainSummaryAccessibility(
        _ score: Double,
        presentation: DailyStrainGaugePresentation
    ) -> String {
        let scoreText = score.formatted(.number.precision(.fractionLength(1)))
        guard let range = report.targetRange else {
            return "Strain index \(scoreText) out of 10. More history needed to show your usual range."
        }
        return "Strain index \(scoreText) out of 10. \(presentation.band.title). Usual range \(formatted(range.lowerBound)) to \(formatted(range.upperBound))."
    }

    private func formatted(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}
