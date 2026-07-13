import SwiftData
import SwiftUI

struct HealthDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.theme) private var theme

    let report: RecoveryEngine.Report
    let metrics: [RecoveryEngine.DailyHealthMetric]
    @State private var selectedTab: MetricDetailTab = .today

    private var assessment: HealthRangeAssessment {
        .make(metrics: metrics)
    }

    private var supplementalSignals: [RecoveryEngine.Signal] {
        let separated = Set([
            "HRV", "Resting HR", "Sleep", "Respiratory", "Blood O₂",
            "Load ratio", "Monotony", "Steps", "Active energy",
        ])
        return report.signals.filter { !separated.contains($0.name) && $0.connected }
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
            baselineValues: channel.baselineValues
        )
    }

    private var heartRateTrend: MetricTrendSeries? {
        guard let channel = heartRateChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues
        )
    }

    private var respiratoryTrend: MetricTrendSeries? {
        guard let channel = respiratoryChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues
        )
    }

    private var oxygenTrend: MetricTrendSeries? {
        guard let channel = oxygenChannel else { return nil }
        return MetricTrendSeries.make(
            values: channel.values,
            baselineValues: channel.baselineValues
        )
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
    }

    @ViewBuilder
    private var todayContent: some View {
        statusSummary

        if !assessment.readings.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Signals vs personal range")
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

        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Label("Readings, not another score", systemImage: "checkmark.shield.fill")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text("Health shows the measurements behind recovery without blending them into a second readiness number. Only signals with enough history are labeled against your personal range.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var trendsContent: some View {
        if let trend = hrvTrend {
            trendCard(
                title: "HRV vs baseline",
                value: "\(Int((trend.latest?.value ?? 0).rounded())) ms",
                metricName: "HRV",
                trend: trend,
                tint: theme.secondaryAccent
            )
        }

        if let trend = heartRateTrend {
            trendCard(
                title: "\(heartRateChannel?.name ?? "Heart rate") vs baseline",
                value: "\(Int((trend.latest?.value ?? 0).rounded())) bpm",
                metricName: "Heart rate",
                trend: trend,
                tint: theme.recoveryMid
            )
        }

        if let trend = respiratoryTrend {
            trendCard(
                title: "Respiratory rate vs baseline",
                value: "\((trend.latest?.value ?? 0).formatted(.number.precision(.fractionLength(1)))) br/min",
                metricName: "Respiratory rate",
                trend: trend,
                tint: theme.zone2
            )
        }

        if let trend = oxygenTrend {
            trendCard(
                title: "Blood oxygen vs baseline",
                value: "\(Int((trend.latest?.value ?? 0).rounded()))%",
                metricName: "Blood oxygen",
                trend: trend,
                tint: theme.secondaryAccent
            )
        }

        if hrvTrend == nil, heartRateTrend == nil, respiratoryTrend == nil, oxygenTrend == nil {
            MetricEmptyCard(
                title: "Health trends are building",
                message: "Seven consistent readings unlock personal range charts.",
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
        guard let mean = reading.mean else {
            return ("Personal range is building", theme.textTertiary)
        }
        let baseline = "usual \(formattedValue(mean, for: reading))"
        switch reading.status {
        case .typical:
            return ("Within your range - \(baseline)", theme.success)
        case .belowRange:
            return ("Below your range - \(baseline)", reading.id == "hrv" ? theme.recoveryLow : theme.secondaryAccent)
        case .aboveRange:
            return ("Above your range - \(baseline)", reading.id == "resting-heart-rate" ? theme.recoveryLow : theme.secondaryAccent)
        case .building:
            return ("Personal range is building", theme.textTertiary)
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
                Text("Shaded area: your recent mean +/- one standard deviation.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}
