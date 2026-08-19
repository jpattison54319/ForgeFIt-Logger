import SwiftUI

/// A quiet hierarchy cue used only when a mesocycle owns child microcycles.
/// Leaf folders and root routines stay flat, so visual depth always represents
/// a real parent-child relationship.
struct RoutineHierarchyRail<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Rectangle()
                .fill(theme.separator)
                .frame(width: 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.md) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Space.sm)
    }
}
