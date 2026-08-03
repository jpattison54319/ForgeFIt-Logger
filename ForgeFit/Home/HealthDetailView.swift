import SwiftData
import SwiftUI

struct HealthDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let report: RecoveryEngine.Report
    let metrics: [RecoveryEngine.DailyHealthMetric]
    @State private var selectedTab: MetricDetailTab = .today
    @State private var showingInfo = false

    private var assessment: HealthRangeAssessment {
        .make(metrics: metrics)
    }

    private var supplementalSignals: [RecoveryEngine.Signal] {
        HealthDetailSignalFilter.supplemental(from: report.signals)
    }

    private var hrvChannel: HealthMetricChannelSeries? {
        .hrv(metrics: metrics)
    }

    private var heartRateChannel: HealthMetricChannelSeries? {
        .heartRate(metrics: metrics)
    }

    private var respiratoryChannel: HealthMetricChannelSeries? {
        .respiratoryRate(metrics: metrics)
    }

    private var oxygenChannel: HealthMetricChannelSeries? {
        .oxygenSaturation(metrics: metrics)
    }

    private var hrvTrend: MetricTrendSeries? {
        guard let channel = hrvChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues,
            baselineDates: channel.baselineDates
        )
    }

    private var heartRateTrend: MetricTrendSeries? {
        guard let channel = heartRateChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues,
            baselineDates: channel.baselineDates
        )
    }

    private var respiratoryTrend: MetricTrendSeries? {
        guard let channel = respiratoryChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues,
            baselineDates: channel.baselineDates
        )
    }

    private var oxygenTrend: MetricTrendSeries? {
        guard let channel = oxygenChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues,
            baselineDates: channel.baselineDates
        )
    }

    private var hasAnyTrend: Bool {
        hrvTrend != nil || heartRateTrend != nil || respiratoryTrend != nil || oxygenTrend != nil
    }

    private var hasLowBloodOxygen: Bool {
        assessment.readings.contains {
            $0.id == "blood-oxygen" && $0.status == .belowRange
        }
    }

    var body: some View {
        MetricDetailScaffold(title: "Health", selectedTab: $selectedTab) {
            switch selectedTab {
            case .today:
                todayContent
            case .trends:
                trendsContent
            }
        }
        .refreshable { await AppRefresh.run(in: modelContext) }
        .sheet(isPresented: $showingInfo) {
            MetricExplanationSheet(
                title: "How health ranges work",
                summary: "Health shows individual readings. It does not combine them into a second health or recovery score.",
                items: [
                    MetricExplanationItem(
                        "Personal ranges",
                        detail: "Each reading is compared only with the same source and measurement channel from your own history.",
                        systemImage: "person.crop.circle"
                    ),
                    MetricExplanationItem(
                        "Enough history",
                        detail: "A usual range needs 28 comparable readings spanning at least 42 days and shows the middle 80% of those observations.",
                        systemImage: "chart.line.uptrend.xyaxis"
                    ),
                    MetricExplanationItem(
                        "Not a medical range",
                        detail: "Usual for you does not mean medically normal. Blood oxygen is a wellness estimate; repeat a concerning reading. Seek care for shortness of breath, chest pain, confusion, or blue or gray lips. Symptoms take priority over every displayed range.",
                        systemImage: "cross.case.fill"
                    ),
                ]
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var todayContent: some View {
        statusSummary

        if !assessment.readings.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Compared with usual")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    ForEach(Array(assessment.readings.enumerated()), id: \.element.id) { index, reading in
                        if index > 0 { Divider().overlay(theme.separator) }
                        personalRangeRow(reading)
                    }
                }
            }
        }

        if !supplementalSignals.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Other readings")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    ForEach(Array(supplementalSignals.enumerated()), id: \.element.id) { index, signal in
                        if index > 0 { Divider().overlay(theme.separator) }
                        MetricReadingRow(
                            title: signal.name,
                            value: signal.value,
                            systemImage: signal.systemImage,
                            detail: signal.detail,
                            tint: theme.accent
                        )
                    }
                }
            }
        }

        if hasLowBloodOxygen {
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Blood oxygen is below usual", systemImage: "exclamationmark.triangle.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Text("Rest, check watch fit, and repeat the reading. Seek medical care for a persistent concern or urgent symptoms.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        MetricInfoLink(title: "How health ranges work") {
            showingInfo = true
        }
    }

    @ViewBuilder
    private var trendsContent: some View {
        if hasAnyTrend {
            Label("Shading shows your personal 10th–90th percentile range.", systemImage: "rectangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }

        if let trend = hrvTrend {
            trendCard(
                title: "HRV",
                value: "\(Int((trend.latest?.value ?? 0).rounded())) ms",
                metricName: "HRV",
                trend: trend,
                tint: theme.secondaryAccent
            )
        }

        if let trend = heartRateTrend {
            trendCard(
                title: heartRateChannel?.name ?? "Heart rate",
                value: "\(Int((trend.latest?.value ?? 0).rounded())) bpm",
                metricName: "Heart rate",
                trend: trend,
                tint: theme.recoveryMid
            )
        }

        if let trend = respiratoryTrend {
            trendCard(
                title: "Respiratory rate",
                value: "\((trend.latest?.value ?? 0).formatted(.number.precision(.fractionLength(1)))) br/min",
                metricName: "Respiratory rate",
                trend: trend,
                tint: theme.zone2
            )
        }

        if let trend = oxygenTrend {
            trendCard(
                title: "Blood oxygen",
                value: "\(Int((trend.latest?.value ?? 0).rounded()))%",
                metricName: "Blood oxygen",
                trend: trend,
                tint: theme.secondaryAccent
            )
        }

        if hrvTrend == nil, heartRateTrend == nil, respiratoryTrend == nil, oxygenTrend == nil {
            MetricEmptyCard(
                title: "Health trends are building",
                message: "A usual observed band needs 28 comparable readings spanning at least 42 days.",
                systemImage: "waveform.path.ecg"
            )
        }
    }

    private var statusSummary: some View {
        let outside = assessment.outsideRangeCount
        let tint = outside > 0 ? theme.recoveryLow : assessment.evaluatedCount > 0 ? theme.success : theme.textTertiary
        return Card {
            HStack(spacing: Space.lg) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.12))
                        .frame(width: 58, height: 58)
                    Image(systemName: outside > 0 ? "exclamationmark.triangle.fill" : assessment.evaluatedCount > 0 ? "checkmark.circle.fill" : "waveform.path.ecg")
                        .font(.system(size: 23, weight: .bold))
                        .foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(assessment.headline)
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(assessment.caption)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .accessibilityIdentifier("health-today-summary")
    }

    private func personalRangeRow(_ reading: PersonalRangeReading) -> some View {
        let presentation = rangePresentation(reading)
        return MetricReadingRow(
            title: reading.name,
            value: formattedValue(reading.value, for: reading),
            systemImage: reading.systemImage,
            detail: presentation.detail,
            tint: presentation.tint
        )
    }

    private func rangePresentation(_ reading: PersonalRangeReading) -> (detail: String, tint: Color) {
        guard let lower = reading.lowerBound, let upper = reading.upperBound else {
            return ("Usual range building", theme.textTertiary)
        }
        let baseline = "\(formattedValue(lower, for: reading))–\(formattedValue(upper, for: reading))"
        switch reading.status {
        case .typical:
            return ("Within usual · \(baseline)", theme.success)
        case .belowRange:
            let tint = reading.id == "hrv" || reading.id == "blood-oxygen"
                ? theme.recoveryLow
                : theme.secondaryAccent
            return ("Below usual · \(baseline)", tint)
        case .aboveRange:
            let tint = reading.id == "resting-heart-rate" || reading.id == "respiratory-rate"
                ? theme.recoveryLow
                : theme.secondaryAccent
            return ("Above usual · \(baseline)", tint)
        case .building:
            return ("Usual range building", theme.textTertiary)
        }
    }

    private func formattedValue(_ value: Double, for reading: PersonalRangeReading) -> String {
        switch reading.id {
        case "respiratory-rate":
            return "\(value.formatted(.number.precision(.fractionLength(1)))) \(reading.unit)"
        case "blood-oxygen":
            return "\(Int(value.rounded()))\(reading.unit)"
        default:
            return "\(Int(value.rounded())) \(reading.unit)"
        }
    }

    private func trendCard(
        title: String,
        value: String,
        metricName: String,
        trend: MetricTrendSeries,
        tint: Color
    ) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(value)
                        .font(.tag)
                        .foregroundStyle(theme.textSecondary)
                }
                MetricBaselineBandChart(trend: trend, metricName: metricName, tint: tint)
            }
        }
    }
}
