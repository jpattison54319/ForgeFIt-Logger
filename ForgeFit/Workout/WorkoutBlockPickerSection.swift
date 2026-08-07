import SwiftUI

/// Visible session-shaped additions above the searchable exercise catalog.
/// Labels and icons both carry meaning so the choice is not color-dependent.
struct WorkoutBlockPickerSection: View {
    @Environment(\.theme) private var theme

    let onAddConditioning: () -> Void
    let onAddYoga: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("WORKOUT BLOCKS")
                .font(.tag)
                .foregroundStyle(theme.textSecondary)

            HStack(spacing: Space.sm) {
                WorkoutBlockPickerButton(
                    title: "Conditioning",
                    detail: "Circuits, intervals, AMRAPs",
                    systemImage: "stopwatch",
                    tint: theme.warmup,
                    accessibilityIdentifier: "add-conditioning-block",
                    action: onAddConditioning
                )
                WorkoutBlockPickerButton(
                    title: "Yoga",
                    detail: "Build a guided pose flow",
                    systemImage: "figure.yoga",
                    tint: theme.accent,
                    accessibilityIdentifier: "add-yoga-block",
                    action: onAddYoga
                )
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
    }
}

private struct WorkoutBlockPickerButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Label(title, systemImage: systemImage)
                    .font(.bodyStrong)
                    .foregroundStyle(tint)
                Text(detail)
                    .font(.label)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(Space.sm)
            .background(theme.surfaceElevated)
            .clipShape(.rect(cornerRadius: Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
