import SwiftUI

/// Detail screen for reminder and cue settings, navigated to from the main
/// settings list. Contains the notification permission/scheduling card plus
/// the timer sound, rest alarm, and pace announcement toggles.
struct RemindersDetailView: View {
    @Environment(\.theme) private var theme

    @AppStorage("timerSoundEnabled") private var timerSoundEnabled = true
    @AppStorage("paceAnnouncementsEnabled") private var paceAnnouncementsEnabled = true
    @AppStorage("loudRestAlarmEnabled") private var loudRestAlarm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                ReminderSettingsCard()

                Card {
                    Toggle(isOn: $timerSoundEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Timer sound").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Text("ForgeFit's forge-strike chime when a rest timer ends — briefly dips your music instead of stopping it. The haptic always fires.")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(theme.accent)
                    .onChange(of: timerSoundEnabled) { _, newValue in
                        if newValue { TimerChime.shared.play() }
                    }
                }

                Card {
                    Toggle(isOn: $loudRestAlarm) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Louder rest alerts").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Text("Extra pings when rest ends — sound breaks through Focus and Do Not Disturb, with no alarm screen to dismiss. Off by default.")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(theme.accent)
                    .onChange(of: loudRestAlarm) { _, newValue in
                        guard newValue else { return }
                        Task {
                            if await !RestAlarm.requestAuthorization() {
                                loudRestAlarm = false
                            }
                        }
                    }
                }

                Card {
                    Toggle(isOn: $paceAnnouncementsEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pace announcements").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            Text("Spoken split time each kilometer or mile on outdoor cardio — music dips briefly, then recovers.")
                                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(theme.accent)
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
    }
}
