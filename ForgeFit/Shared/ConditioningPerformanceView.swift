import ForgeCore
import SwiftUI

/// Completed-workout analysis for one conditioning section. Aggregate metrics
/// remain available for older logs; the round chart appears only when exact,
/// comparable round checkpoints were captured.
struct ConditioningPerformanceView: View {
    let section: ConditioningSection
    let result: ConditioningSectionResult
    var sectionName: String?

    @Environment(\.theme) private var theme

    private var analysis: ConditioningPerformanceAnalysis {
        ConditioningPerformanceAnalysis(section: section, result: result)
    }

    private var facts: [ConditioningSharePresentation.Fact] {
        Array(ConditioningSharePresentation.performanceFacts(
            section: section,
            result: result
        ).prefix(3))
    }

    private var chartSplits: [ConditioningPerformanceAnalysis.RoundSplit] {
        analysis.averageLoggedSplitSeconds == nil ? [] : analysis.roundSplits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)

            Label(sectionName.map { "\($0) analysis" } ?? "Performance", systemImage: "chart.xyaxis.line")
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)

            HStack(spacing: Space.md) {
                ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                    StatColumn(
                        label: fact.label,
                        value: fact.value,
                        valueColor: fact.label == "2nd half" ? paceChangeColor : theme.warmup
                    )
                }
            }

            if chartSplits.count >= 2, let average = analysis.averageLoggedSplitSeconds {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Round pace")
                            .font(.tag)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("\(chartSplits.count) splits")
                            .font(.tag)
                            .foregroundStyle(theme.textTertiary)
                    }

                    ConditioningRoundPaceChart(
                        splits: chartSplits,
                        averageSeconds: average
                    )
                }
            }
        }
    }

    private var paceChangeColor: Color {
        guard let change = analysis.secondHalfPaceChangePercent else { return theme.textPrimary }
        if abs(change) < 3 { return theme.textSecondary }
        return change > 0 ? theme.warmup : theme.success
    }
}
