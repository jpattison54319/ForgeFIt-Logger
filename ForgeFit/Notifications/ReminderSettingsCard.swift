import SwiftUI

/// The Settings card for workout reminders: explicit permission flow plus
/// weekday and time scheduling.
struct ReminderSettingsCard: View {
    @Environment(\.theme) private var theme
    @State private var scheduler = NotificationScheduler.shared
    @State private var weekdays: Set<Int> = NotificationScheduler.shared.reminderWeekdays
    @State private var time: Date = {
        let minutes = NotificationScheduler.shared.reminderMinutes
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }()
    @State private var morningReadiness = NotificationScheduler.shared.morningReadinessEnabled

    private static let weekdaySymbols = ["S", "M", "T", "W", "T", "F", "S"] // 1...7 Sun–Sat

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            switch scheduler.authorizationStatus {
            case .denied:
                deniedCard
            case .authorized, .provisional, .ephemeral:
                configCards
            default:
                notAskedCard
            }
        }
        .onAppear { scheduler.refreshStatus() }
    }

    private var notAskedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Workout reminders").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Text("Get a nudge on training days and rest-timer alerts while your phone is locked.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                PrimaryButton(title: "Enable Notifications", systemImage: "bell.fill") {
                    Task { _ = await scheduler.requestPermission() }
                }
            }
        }
    }

    private var deniedCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(spacing: 6) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(theme.textTertiary)
                    Text("Notifications are off").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                }
                Text("Turn them on in Settings to get workout reminders and locked-phone rest alerts.")
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                SecondaryButton(title: "Open Settings", systemImage: "arrow.up.right") {
                    scheduler.openSystemSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var configCards: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Training days").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                // Seven equal-weight day buttons across one row: there's no
                // width budget on smaller phones to grow these to the full
                // 44x44 HIG target without wrapping the row. `.contentShape`
                // adds a couple points of hit area on each side instead — the
                // most that fits the 8pt gaps here without adjacent buttons'
                // tap regions touching.
                HStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { weekday in
                        let on = weekdays.contains(weekday)
                        Button {
                            if on { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                            scheduler.reminderWeekdays = weekdays
                        } label: {
                            Text(Self.weekdaySymbols[weekday - 1])
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(on ? .white : theme.textSecondary)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(on ? theme.accent : theme.surfaceElevated))
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle().inset(by: -2))
                    }
                }
                if !weekdays.isEmpty {
                    DatePicker("Remind me at", selection: $time, displayedComponents: .hourAndMinute)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                        .tint(theme.accent)
                        .onChange(of: time) { _, newValue in
                            let components = Calendar.current.dateComponents([.hour, .minute], from: newValue)
                            scheduler.reminderMinutes = (components.hour ?? 17) * 60 + (components.minute ?? 30)
                        }
                } else {
                    Text("Pick the days you plan to train.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
            }
        }
        Card {
            Toggle(isOn: $morningReadiness) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Morning readiness").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("Your score and the day's call (7 AM), computed from last night's sleep and HRV.")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
            }
            .tint(theme.accent)
            .onChange(of: morningReadiness) { _, newValue in
                scheduler.morningReadinessEnabled = newValue
                if newValue { ReadinessDelivery.shared.refreshMorningNotification() }
            }
        }
    }
}
