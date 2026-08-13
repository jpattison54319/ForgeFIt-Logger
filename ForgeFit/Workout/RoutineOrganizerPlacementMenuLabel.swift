import SwiftUI

/// Gives the compact placement action a forgiving hit region while keeping
/// the familiar ellipsis visually quiet beside the system reorder handle.
struct RoutineOrganizerPlacementMenuLabel: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
    }
}
