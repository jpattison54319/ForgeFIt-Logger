import SwiftUI

/// Apple Watch live-sync toggle section with pairing status footer.
struct SettingsWatchSection: View {
    @Environment(\.theme) private var theme
    @State private var watch = WatchLink.shared

    @AppStorage("liveSyncEnabled") private var liveSyncEnabled = true

    var body: some View {
        Section {
            Toggle(isOn: $liveSyncEnabled) {
                SettingsRowLabel(
                    icon: "applewatch",
                    iconTint: theme.accent,
                    title: "Live sync with Apple Watch",
                    subtitle: "Pull heart rate, distance & calories live from your Watch during a session."
                )
            }
            .tint(theme.accent)
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Apple Watch")
        } footer: {
            Text(watchStatusFooter)
        }
    }

    private var watchStatusFooter: String {
        if !watch.isPaired {
            return "Pair an Apple Watch in the Watch app, then keep it on during workouts for automatic metrics."
        } else {
            var parts: [String] = ["Paired"]
            parts.append(watch.isWatchAppInstalled ? "Watch app installed" : "Watch app not installed")
            parts.append(watch.isReachable ? "Reachable" : "Not reachable")
            return parts.joined(separator: " \u{00B7} ")
        }
    }
}
