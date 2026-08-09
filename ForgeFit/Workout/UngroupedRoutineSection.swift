import SwiftUI
import UniformTypeIdentifiers

/// Root-level routines are a lightweight disclosure, not a synthetic folder.
/// The wrapper remains a drop target while collapsed so moving a routine to
/// Ungrouped never depends on the current presentation preference.
struct UngroupedRoutineSection<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isCollapsed: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Button(action: toggle) {
                HStack(spacing: Space.sm) {
                    Text("Ungrouped")
                    Spacer(minLength: Space.md)
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textSecondary)
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
        .onDrop(of: [UTType.plainText], isTargeted: nil, perform: onDrop)
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
