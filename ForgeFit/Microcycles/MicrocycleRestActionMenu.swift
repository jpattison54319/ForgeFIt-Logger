import SwiftUI

struct MicrocycleRestActionMenu: View {
    @Environment(\.theme) private var theme

    let canAddPlannedRest: Bool
    let onLogAdHoc: () -> Void
    let onAddToRoutine: () -> Void

    var body: some View {
        Menu {
            Button("Log Rest Day Ad Hoc", systemImage: "calendar.badge.checkmark", action: onLogAdHoc)
            Button("Add Rest Day to Routine", systemImage: "text.badge.plus", action: onAddToRoutine)
                .disabled(!canAddPlannedRest)
        } label: {
            HStack(spacing: Space.sm) {
                Label("Rest Day Options", systemImage: "moon.zzz")
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
                    .accessibilityHidden(true)
            }
            .font(.bodyStrong)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: Radius.control))
        .accessibilityLabel("Rest Day Options")
        .accessibilityIdentifier("microcycle-rest-day-menu")
    }
}
