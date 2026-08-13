import Charts
import ForgeCore
import SwiftUI

/// Exact active-time splits for comparable rounds. A straight line preserves
/// the logged shape; no smoothing implies intermediate measurements.
struct ConditioningRoundPaceChart: View {
    let splits: [ConditioningPerformanceAnalysis.RoundSplit]
    let averageSeconds: Int

    @Environment(\.theme) private var theme

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
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(theme.separator.opacity(0.5))
                if let seconds = value.as(Double.self) {
                    AxisValueLabel {
                        Text(Fmt.elapsed(Int(seconds.rounded())))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .ignore)
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
