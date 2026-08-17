import SwiftUI

struct MicrocycleHistoryEducationSheet: View {
    @Environment(\.theme) private var theme

    let onViewHistory: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: Space.lg) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.largeTitle)
                .foregroundStyle(theme.accentForeground)
                .accessibilityHidden(true)

            VStack(spacing: Space.sm) {
                Text("Microcycle history saved")
                    .font(.sectionTitle)
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Your logged cycles are available anytime in Profile → Microcycles.")
                    .font(.body)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            PrimaryButton(
                title: "View History",
                systemImage: "clock.arrow.circlepath",
                action: onViewHistory
            )
            .accessibilityIdentifier("view-microcycle-history-after-stop")

            SecondaryButton(title: "Done", action: onDone)
                .accessibilityIdentifier("dismiss-microcycle-history-education")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
