import Charts
import ForgeCore
import SwiftUI

/// Exact active-time splits for comparable rounds. A straight line preserves
/// the logged shape; no smoothing implies intermediate measurements.
struct ConditioningRoundPaceChart: View {
    let splits: [ConditioningPerformanceAnalysis.RoundSplit]
    let averageSeconds: Int

    @Environment(\.theme) private var theme
    @State private var selectedRound: Int?

    private var selectedSplit: ConditioningPerformanceAnalysis.RoundSplit? {
        guard let selectedRound else { return nil }
        return splits.min { abs($0.round - selectedRound) < abs($1.round - selectedRound) }
    }

    var body: some View {
        Chart {
            RuleMark(y: .value("Average", Double(averageSeconds)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(theme.textTertiary)

            ForEach(splits) { split in
                LineMark(
                    x: .value("Round", split.round),
                    y: .value("Seconds", Double(split.durationSeconds))
                )
                .interpolationMethod(.linear)
                .foregroundStyle(theme.warmup)
                .lineStyle(StrokeStyle(lineWidth: 2.5))

                PointMark(
                    x: .value("Round", split.round),
                    y: .value("Seconds", Double(split.durationSeconds))
                )
                .foregroundStyle(theme.warmup)
                .symbolSize(48)
            }
            if let selectedSplit {
                RuleMark(x: .value("Selected round", selectedSplit.round))
                    .foregroundStyle(theme.textTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartSelectionCallout(
                            title: "Round \(selectedSplit.round)",
                            lines: [("Time", Fmt.elapsed(selectedSplit.durationSeconds))]
                        )
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(6, splits.count))) { value in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.35))
                if let round = value.as(Int.self) {
                    AxisValueLabel { Text("R\(round)").foregroundStyle(theme.textTertiary) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                if let seconds = value.as(Double.self) {
                    AxisValueLabel {
                        Text(Fmt.elapsed(Int(seconds.rounded())))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .chartYAxisLabel(position: .top, alignment: .leading) {
            Text("Time (min:sec)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
        }
        .pressHoldChartXSelection(value: $selectedRound)
        .frame(height: 150)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Round pace")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("conditioning-round-pace-chart")
    }

    private var accessibilityValue: String {
        splits
            .map { "Round \($0.round), \(Fmt.elapsed($0.durationSeconds))" }
            .joined(separator: "; ")
    }
}
