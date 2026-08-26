import SwiftUI

/// Persistent completion controls that stay available while the workout
/// summary scrolls underneath them.
struct PostWorkoutActionBar: View {
    let onKeepLogging: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void
    /// True while a finish is committing: the Save control disables and reads
    /// "Saving…" so a rapid second tap cannot re-enter the finisher (FF-006).
    let isSaving: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        GlassEffectContainer(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                CircleIconButton(
                    systemImage: "chevron.backward",
                    label: "Keep logging",
                    action: onKeepLogging
                )
                .accessibilityIdentifier("post-workout-keep-logging-button")

                Spacer(minLength: Space.sm)

                CircleIconButton(
                    systemImage: "square.and.arrow.up",
                    label: "Share workout",
                    action: onShare
                )
                .accessibilityIdentifier("post-workout-share-button")

                Button(isSaving ? "Saving…" : "Save Workout", systemImage: "checkmark", action: onSave)
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(theme.accent)
                    .disabled(isSaving)
                    .accessibilityLabel(isSaving ? "Saving workout" : "Save workout")
                    .accessibilityIdentifier("save-workout-button")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }
}
