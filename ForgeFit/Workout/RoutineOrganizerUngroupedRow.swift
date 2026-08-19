import SwiftUI

struct RoutineOrganizerUngroupedRow: View {
    @Environment(\.theme) private var theme

    let count: Int

    var body: some View {
        HStack(spacing: Space.sm) {
            Text("Ungrouped")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .listRowBackground(theme.background)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("organizer-ungrouped")
    }
}
