import SwiftUI

struct SleepTargetCard: View {
    @Environment(\.theme) private var theme

    let minutes: Int
    let action: () -> Void

    var body: some View {
        Card {
            Button(action: action) {
                HStack(spacing: Space.md) {
                    Image(systemName: "target")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(theme.zone2)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleep target")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(SleepMetricPresentation.duration(minutes))
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textTertiary)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sleep target, \(SleepMetricPresentation.duration(minutes))")
            .accessibilityHint("Opens the sleep target editor")
            .accessibilityIdentifier("sleep-target-edit")
        }
    }
}
