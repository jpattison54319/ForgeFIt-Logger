import SwiftUI

/// A calm, explicit decision surface shown after the user asks to save a
/// changed workout. Both outcomes save the workout; only the first also
/// carries the structural changes into future uses of the saved routine.
struct RoutineUpdateSheet: View {
    @Environment(\.theme) private var theme

    let prompt: RoutineUpdatePrompt
    let onUpdateAndSave: () -> Void
    let onSaveOnly: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2.bold())
                        .foregroundStyle(theme.accentForeground)
                        .frame(width: 52, height: 52)
                        .background(theme.accentSoft, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text("Update saved routine?")
                            .font(.sectionTitle)
                            .foregroundStyle(theme.textPrimary)

                        Text("You made changes during this workout. Would you like to apply them to \(prompt.routineReference) for next time?")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !prompt.changeSummary.isEmpty {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Label("Changes", systemImage: "list.bullet")
                                .font(.label)
                                .foregroundStyle(theme.textSecondary)

                            Text(prompt.changeSummary)
                                .font(.bodyStrong)
                                .foregroundStyle(theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: Radius.card))
                        .accessibilityElement(children: .combine)
                    }
                }

                VStack(spacing: Space.md) {
                    PrimaryButton(
                        title: "Update Routine & Save Workout",
                        systemImage: "arrow.triangle.2.circlepath",
                        action: onUpdateAndSave
                    )
                    .accessibilityIdentifier("update-routine-and-save-workout-button")

                    SecondaryButton(
                        title: "Save Workout Only",
                        systemImage: "checkmark",
                        action: onSaveOnly
                    )
                    .accessibilityIdentifier("save-workout-only-button")
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(theme.background)
        .presentationBackground(theme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
    }
}
