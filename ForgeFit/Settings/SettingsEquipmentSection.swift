import SwiftUI

/// Equipment section: navigation link to the plate inventory editor.
struct SettingsEquipmentSection: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.platesAndBars) {
                SettingsRowLabel(
                    icon: "scalemass.fill",
                    iconTint: theme.accent,
                    title: "Plates & Bars",
                    subtitle: "Bar weight and plate inventory for the plate calculator."
                )
            }
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Equipment")
        }
    }
}
