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
                        y: .value(metricName, point.value)
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
                    .accessibilityLabel("\(metricName), \(point.date.formatted(date: .abbreviated, time: .omitted))")
                    .accessibilityValue(valueFormatter(point.value))
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(chartAccessibilityLabel ?? "\(metricName) exercise progress chart")
        .accessibilityValue(selectedAccessibilityValue)
        .accessibilityIdentifier(chartAccessibilityIdentifier)
        .onChange(of: points.last?.id) {
            selectedDate = nil
        }
    }

    private var selectedAccessibilityValue: String {
        guard selectedDate != nil, let selectedPoint else {
            return "Press and hold, then slide to inspect measurements"
        }
        return "\(selectedPoint.date.formatted(date: .abbreviated, time: .omitted)), "
            + valueFormatter(selectedPoint.value)
    }
}
