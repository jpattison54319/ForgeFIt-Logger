import SwiftUI

/// Compact, render-safe metric strip shared by the fixed-size and long workout
/// image layouts.
struct ConditioningShareMetricsRow: View {
    let facts: [ConditioningSharePresentation.Fact]
    let theme: AppTheme
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            ForEach(Array(facts.prefix(compact ? 2 : 3).enumerated()), id: \.offset) { _, fact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.value)
                        .font(.system(size: compact ? 12 : 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.warmup)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text(fact.label.uppercased())
                        .font(.system(size: compact ? 8 : 9, weight: .heavy))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
