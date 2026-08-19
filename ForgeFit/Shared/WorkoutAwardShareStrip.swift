import SwiftUI

/// Compact award proof for generated workout images.
struct WorkoutAwardShareStrip: View {
    let awards: [WorkoutAward]
    let theme: AppTheme
    var compact = false

    private var visibleAwards: [WorkoutAward] {
        Array(awards.prefix(compact ? 1 : 3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            ForEach(visibleAwards) { award in
                HStack(spacing: 7) {
                    Image(systemName: award.kind.icon)
                        .font(.system(size: compact ? 10 : 12, weight: .bold))
                        .foregroundStyle(theme.warmup)
                        .frame(width: compact ? 21 : 26, height: compact ? 21 : 26)
                        .background(theme.warmup.opacity(0.15))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(award.kind.label)
                            .font(.system(size: compact ? 11 : 13, weight: .bold))
                            .foregroundStyle(theme.warmup)
                        if !compact {
                            Text(award.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(award.valueText)
                        .font(.system(size: compact ? 12 : 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, compact ? 9 : 12)
        .padding(.vertical, compact ? 6 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.warmup.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 12))
        .accessibilityElement(children: .combine)
    }
}
