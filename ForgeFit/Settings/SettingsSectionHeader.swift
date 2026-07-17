import SwiftUI

/// Reusable section header for settings list sections.
struct SettingsSectionHeader: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
    }
}
