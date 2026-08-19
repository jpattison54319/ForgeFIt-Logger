import SwiftUI

/// Root-level routines are a lightweight disclosure, not a synthetic folder.
struct UngroupedRoutineSection<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isCollapsed: Bool
    let count: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Button(action: toggle) {
                HStack(spacing: Space.sm) {
                    Text("Ungrouped")
                    Text("\(count)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(theme.surfaceElevated)
                        .clipShape(Capsule())
                    Spacer(minLength: Space.md)
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isCollapsed ? theme.textSecondary : theme.accent)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.plain)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(theme.textPrimary)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("ungrouped-routines-disclosure")

            if !isCollapsed {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle() {
        if reduceMotion {
            isCollapsed.toggle()
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                isCollapsed.toggle()
            }
        }
    }
}
