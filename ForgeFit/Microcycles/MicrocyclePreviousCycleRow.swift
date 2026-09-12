import ForgeData
import SwiftUI

/// Browsing uses stored metadata; full progress is reconstructed only on opening a cycle.
struct MicrocyclePreviousCycleRow: View {
    @Environment(\.theme) private var theme
    let window: MicrocycleWindowModel
    let cutoff: Date

    var body: some View {
        NavigationLink(value: MicrocycleHistoryRoute.window(
            trackingID: window.trackingID,
            windowID: window.id
        )) {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Cycle \(window.index + 1)")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("\(window.startsAt.formatted(date: .abbreviated, time: .omitted))–\(min(window.endsAt.addingTimeInterval(-1), cutoff).formatted(date: .abbreviated, time: .omitted))")
                            .font(.subheadline)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: TouchTarget.minimum)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("microcycle-previous-window-\(window.index + 1)")
    }
}
