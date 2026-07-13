import SwiftUI

/// Compact provenance marker for a sleep value the user resolved on Home.
/// Text and icon both carry the meaning so it remains clear without color.
struct SleepOverrideStatusBadge: View {
    @Environment(\.theme) private var theme

    let status: RecoveryEngine.SleepOverrideStatus

    var body: some View {
        Label(status.label, systemImage: status.systemImage)
            .font(.tag)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .fixedSize()
            .accessibilityLabel("Sleep status: \(status.label)")
            .accessibilityIdentifier("recovery-sleep-override-\(identifierSuffix)")
    }

    private var tint: Color {
        switch status {
        case .confirmed: theme.success
        case .edited: theme.accent
        case .notTracked: theme.textSecondary
        }
    }

    private var identifierSuffix: String {
        switch status {
        case .confirmed: "confirmed"
        case .edited: "edited"
        case .notTracked: "not-tracked"
        }
    }
}
