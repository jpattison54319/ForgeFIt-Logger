import SwiftUI

struct MicrocycleRestDragPreview: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "moon.zzz")
                .accessibilityHidden(true)
            Text("Rest Day")
                .font(.bodyStrong)
            Image(systemName: "line.3.horizontal")
                .accessibilityHidden(true)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, Space.md)
        .frame(height: TouchTarget.minimum)
        .background(theme.surfaceElevated, in: Capsule())
    }
}
