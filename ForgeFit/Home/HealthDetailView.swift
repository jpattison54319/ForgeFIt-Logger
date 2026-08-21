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
            $0.kind == .bloodOxygen && $0.status == .belowRange
        }
    }

    var body: some View {
        MetricDetailScaffold(title: "Vitals", selectedTab: $selectedTab, identifierStem: "health") {
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
                title: "How vital ranges work",
                summary: "Vitals shows individual readings. It does not combine them into a second health or recovery score.",
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
        if assessment.readings.isEmpty {
            MetricEmptyCard(
                title: "No vital readings",
                message: "Connect Apple Health to compare today’s readings with your personal ranges.",
                systemImage: "waveform.path.ecg"
            )
            .accessibilityIdentifier("health-today-summary")
        } else {
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
            .accessibilityIdentifier("health-today-summary")
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
                    Label {
                        Text("Blood oxygen is below usual")
                            .foregroundStyle(theme.textPrimary)
                    } icon: {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(theme.warmup)
                    }
                    .font(.bodyStrong)
                    Text("This compares the reading with your personal history; it is not a medical assessment.")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        MetricInfoLink(title: "How vital ranges work") {
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

        if let trend = hrvTrend {
            trendCard(
                title: "HRV",
                value: "\(Int((trend.latest?.value ?? 0).rounded())) ms",
                metricName: "HRV",
                trend: trend,
                tint: theme.secondaryAccent
            )
        }

        if hrvTrend == nil, heartRateTrend == nil, respiratoryTrend == nil, oxygenTrend == nil {
            MetricEmptyCard(
                title: "Vital trends are building",
                message: "A usual observed band needs 28 comparable readings spanning at least 42 days.",
                systemImage: "waveform.path.ecg"
            )
        }
    }

    private func personalRangeRow(_ reading: PersonalRangeReading) -> some View {
        let presentation = rangePresentation(reading)
        return MetricReadingRow(
            title: reading.name,
            value: reading.formattedVitalValue,
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
            return ("Within usual · \(baseline)", theme.zone2)
        case .belowRange:
            let favorable = reading.interpretation == .favorable
            return (
                "\(favorable ? "Favorable · " : "")Below usual · \(baseline)",
                favorable ? theme.success : theme.warmup
            )
        case .aboveRange:
            let favorable = reading.interpretation == .favorable
            return (
                "\(favorable ? "Favorable · " : "")Above usual · \(baseline)",
                favorable ? theme.success : theme.warmup
            )
        case .building:
            return ("Usual range building", theme.textTertiary)
        }
    }

    private func formattedValue(_ value: Double, for reading: PersonalRangeReading) -> String {
        switch reading.kind {
        case .respiratoryRate:
            return "\(value.formatted(.number.precision(.fractionLength(1)))) \(reading.unit)"
        case .bloodOxygen:
            return "\(Int(value.rounded()))\(reading.unit)"
        case .heartRate, .hrv:
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
