import SwiftUI

/// What the between-set recovery card's symbols mean. Kept to a legend: every
/// row maps to a mark the reader is looking at, so the explanation is scanned
/// rather than read.
struct BetweenSetRecoveryInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack {
                    Text("Between-set recovery")
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                }

                Text("How far your heart rate fell during each rest.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Space.md) {
                    legendRow("164", "Peak heart rate for the round.", color: theme.danger)
                    legendRow("▼75", "It fell 75 bpm before the next round.", color: theme.success)
                    legendRow("▲6", "It climbed 6 bpm across the round.", color: theme.secondaryAccentForeground)
                    legendRow("—", "Under a minute of rest. Nothing to read.", color: theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Bigger drops mean faster recovery — a conditioning signal, not how hard the set was.")
                    Text("A superset round or drop chain has no rest inside it, so it counts as one round.")
                }
                .font(.system(size: 13))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.lg)
        }
        .background(theme.background)
    }

    private func legendRow(_ mark: String, _ detail: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.md) {
            Text(mark)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .leading)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
