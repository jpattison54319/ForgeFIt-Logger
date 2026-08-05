import SwiftUI

/// About section: app version, privacy policy link, and exercise-database
/// credit.
struct SettingsAboutSection: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            SettingsRow(title: "Version") {
                Text(appVersion)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary)
            }
            .themedListRow()

            NavigationLink(value: SettingsRoute.privacyPolicy) {
                SettingsRowLabel(title: "Privacy Policy")
            }
            .themedListRow()

            Link(destination: URL(string: "https://github.com/yuhonas/free-exercise-db")!) {
                HStack(spacing: Space.md) {
                    SettingsRowLabel(title: "Exercise illustrations: free-exercise-db")
                    Spacer(minLength: Space.sm)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "About")
        } footer: {
            Text("Workouts, health metrics, and check-ins stay on this phone. Routines and your exercise library sync through your own iCloud account so they follow you between devices. ForgeFit has no server of its own, so none of it reaches us.")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
