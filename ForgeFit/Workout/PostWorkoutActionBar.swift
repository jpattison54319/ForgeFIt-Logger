import SwiftUI

/// Persistent completion controls that stay available while the workout
/// summary scrolls underneath them.
struct PostWorkoutActionBar: View {
    let onKeepLogging: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void

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

                Button("Save", systemImage: "checkmark", action: onSave)
                    .font(.bodyStrong)
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                    .tint(theme.accent)
                    .accessibilityLabel("Save workout")
                    .accessibilityIdentifier("save-workout-button")
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.sm)
    }
}
