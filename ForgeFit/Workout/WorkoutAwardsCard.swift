import SwiftUI

/// Shared record presentation for the completion summary and workout history.
struct WorkoutAwardsCard: View {
    let awards: [WorkoutAward]

    @Environment(\.theme) private var theme

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Label("Awards", systemImage: "trophy.fill")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.warmup)

                ForEach(awards) { award in
                    HStack(spacing: Space.md) {
                        Image(systemName: award.kind.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.warmup)
                            .frame(width: 28, height: 28)
                            .background(theme.warmup.opacity(0.15))
                            .clipShape(Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(award.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(1)
                            Text(award.kind.label)
                                .font(.system(size: 12))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text(award.valueText)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.warmup)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .accessibilityIdentifier("workout-awards-card")
    }
}
