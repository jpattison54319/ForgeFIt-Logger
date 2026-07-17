import SwiftUI

struct TrophyDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let trophy: Trophy

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.xxl) {
                ZStack {
                    Circle()
                        .fill(trophy.achieved ? theme.accentSoft : theme.surfaceElevated)

                    Image(systemName: trophy.icon)
                        .font(.system(.largeTitle, weight: .bold))
                        .foregroundStyle(trophy.achieved ? theme.accent : theme.textTertiary)
                }
                .frame(width: 104, height: 104)
                .accessibilityHidden(true)

                VStack(spacing: Space.sm) {
                    Text(trophy.title)
                        .font(.sectionTitle)
                        .foregroundStyle(theme.textPrimary)

                    Label(trophy.achieved ? "Earned" : "In progress", systemImage: trophy.achieved ? "checkmark.seal.fill" : "lock.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(trophy.achieved ? theme.success : theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: Space.md) {
                    Text(trophy.requirement)
                        .font(.body)
                        .foregroundStyle(theme.textSecondary)

                    ProgressView(value: trophy.progress)
                        .tint(theme.accent)

                    Text(trophy.progressLabel)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Space.xl)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(theme.background)
            .navigationTitle("Trophy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
