import SwiftUI

/// Launch behavior that users can tailor without changing the current tab.
struct SettingsAppSection: View {
    @AppStorage(DefaultLaunchTab.key) private var defaultTab = DefaultLaunchTab.home

    var body: some View {
        Section {
            Picker(selection: $defaultTab) {
                ForEach(DefaultLaunchTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            } label: {
                SettingsRowLabel(
                    title: "Default tab",
                    subtitle: "Shown when ForgeFit launches."
                )
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("default-tab-picker")
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "App")
        }
    }
}
