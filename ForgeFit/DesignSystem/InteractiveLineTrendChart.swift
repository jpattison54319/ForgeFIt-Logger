import Charts
import SwiftUI

/// A measurement-by-measurement trend chart for exercise progress. Every
/// recorded point stays visible and a deliberate press reveals exact values.
struct InteractiveLineTrendChart: View {
    let points: [MetricPoint]
    let metricName: String
    let valueFormatter: @MainActor (Double) -> String
    var axisValueFormatter: @MainActor (Double) -> String = {
        $0.formatted(.number.precision(.fractionLength(0...1)))
    }
    var yAxisLabel: String? = nil
    /// Use a physical lower bound for quantities that cannot be negative. Leave
    /// nil for signed metrics such as percentage change.
    var yDomainLowerLimit: Double? = nil
    var color: Color? = nil
    var chartAccessibilityLabel: String? = nil
    var chartAccessibilityIdentifier: String = "exercise-progress-chart"

    @Environment(\.theme) private var theme
    @State private var selectedDate: Date?

    private var selectedPoint: MetricPoint? {
        guard let selectedDate else { return points.last }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        let lineColor = color ?? theme.accent
        let yDomain = ChartYDomain.padded(
            values: points.map(\.value),
            lowerLimit: yDomainLowerLimit
        )

        Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value(metricName, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .accessibilityHidden(true)

                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Visible baseline", yDomain.lowerBound),
                        yEnd: .value(metricName, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [lineColor.opacity(0.25), lineColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .accessibilityHidden(true)

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value(metricName, point.value)
                    )
                    .foregroundStyle(lineColor)
                    .symbolSize(28)
                    .accessibilityHidden(true)
                }

                if selectedDate != nil, let selectedPoint {
                    RuleMark(x: .value("Selected date", selectedPoint.date))
                        .foregroundStyle(theme.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .accessibilityHidden(true)
                        .annotation(
                            position: .top,
                            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                        ) {
                            ChartSelectionCallout(
                                title: selectedPoint.date.formatted(date: .abbreviated, time: .omitted),
                                lines: [(metricName, valueFormatter(selectedPoint.value))]
                            )
                        }

                    PointMark(
                        x: .value("Selected date", selectedPoint.date),
                        y: .value(metricName, selectedPoint.value)
                    )
                    .foregroundStyle(lineColor)
                    .symbolSize(90)
                    .accessibilityHidden(true)
                }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(theme.separator.opacity(0.35))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(theme.textTertiary)
                }
        }
        .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                    AxisValueLabel {
                        if let measurement = value.as(Double.self) {
                            Text(axisValueFormatter(measurement))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            if let yAxisLabel {
                Text(yAxisLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .pressHoldChartXSelection(value: $selectedDate)
        .frame(height: 210)
        // Do not expose Swift Charts' raw canonical values alongside the
        // localized display values. VoiceOver users inspect the same formatted
        // points with adjustable actions instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartAccessibilityLabel ?? "\(metricName) exercise progress chart")
        .accessibilityValue(selectedAccessibilityValue(domain: yDomain))
        .accessibilityHint("Swipe up or down to inspect measurements")
        .accessibilityAdjustableAction(adjustAccessibilitySelection)
        .accessibilityIdentifier(chartAccessibilityIdentifier)
        .onChange(of: points.last?.id) {
            selectedDate = nil
        }
    }

    private func selectedAccessibilityValue(domain: ClosedRange<Double>) -> String {
        let range = "Visible range \(axisValueFormatter(domain.lowerBound)) to \(axisValueFormatter(domain.upperBound))"
        if selectedDate != nil, let selectedPoint {
            return "\(selectedPoint.date.formatted(date: .abbreviated, time: .omitted)), "
                + "\(valueFormatter(selectedPoint.value)). \(range)"
        }
        guard let latest = points.last else { return range }
        return "Latest \(valueFormatter(latest.value)). \(range)"
    }

    private func adjustAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        guard !points.isEmpty else { return }
        let currentIndex = selectedPoint.flatMap { selected in
            points.firstIndex(where: { $0.id == selected.id })
        } ?? (points.count - 1)
        let nextIndex: Int
        switch direction {
        case .increment:
            nextIndex = min(points.count - 1, currentIndex + 1)
        case .decrement:
            nextIndex = max(0, currentIndex - 1)
        @unknown default:
            return
        }
        selectedDate = points[nextIndex].date
    }
}
