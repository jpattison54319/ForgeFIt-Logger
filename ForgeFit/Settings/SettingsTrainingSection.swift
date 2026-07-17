import SwiftUI

/// Training section: navigation links to heart-rate zone settings and
/// reminder/cue settings.
struct SettingsTrainingSection: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Section {
            NavigationLink(value: SettingsRoute.heartRateZones) {
                SettingsRowLabel(
                    icon: "heart.text.square.fill",
                    iconTint: theme.danger,
                    title: "Heart-rate zones",
                    subtitle: "Set your max HR, customize zones, or run a zone test."
                )
            }
            .themedListRow()

            NavigationLink(value: SettingsRoute.warmupRamp) {
                SettingsRowLabel(
                    icon: "flame.fill",
                    iconTint: theme.warmup,
                    title: "Warm-up ramp",
                    subtitle: "The warm-up sets added before your working sets."
                )
            }
            .themedListRow()

            NavigationLink(value: SettingsRoute.reminders) {
                SettingsRowLabel(
                    icon: "bell.badge.fill",
                    iconTint: theme.accent,
                    title: "Reminders",
                    subtitle: "Notifications and cues for rest timers and pace."
                )
            }
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Training")
        }
    }
}
