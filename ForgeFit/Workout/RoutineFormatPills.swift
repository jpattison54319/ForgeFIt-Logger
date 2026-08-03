import SwiftUI

/// Compact entry points for session-shaped formats that do not belong in the
/// exercise picker.
struct RoutineFormatPills: View {
    @Environment(\.theme) private var theme

    let onAddConditioning: () -> Void
    let onAddYoga: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Button("Conditioning", systemImage: "plus", action: onAddConditioning)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, Space.sm)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("add-conditioning-format")

                Button("Yoga", systemImage: "plus", action: onAddYoga)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                    .padding(.horizontal, Space.sm)
                    .frame(minHeight: 44)
                    .contentShape(Capsule())
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("add-yoga-format")
            }
        }
    }
}
