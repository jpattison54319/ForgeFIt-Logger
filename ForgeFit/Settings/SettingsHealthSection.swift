import SwiftData
import SwiftUI

/// Apple Health connection section: connect/disconnect status, write toggle,
/// and workout history import.
struct SettingsHealthSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    @Binding var connected: Bool
    @Binding var connecting: Bool
    @Binding var showHistoryImporter: Bool

    @AppStorage("healthWriteEnabled") private var healthWriteEnabled = true

    var body: some View {
        Section {
            if connected {
                SettingsRow(icon: "heart.fill", iconTint: theme.danger, title: "Apple Health", subtitle: "Connected") {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.success)
                }
                .themedListRow()
            } else {
                Button {
                    connect()
                } label: {
                    SettingsRowLabel(
                        icon: "heart.fill",
                        iconTint: theme.danger,
                        title: connecting ? "Connecting\u{2026}" : "Connect Apple Health"
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .disabled(connecting || !HealthService.shared.isAvailable)
            }

            Toggle(isOn: $healthWriteEnabled) {
                SettingsRowLabel(title: "Write workouts to Health", subtitle: "Save each finished session as an Apple Health workout.")
            }
            .tint(theme.accent)
            .themedListRow()

            Button {
                showHistoryImporter = true
            } label: {
                SettingsRowLabel(
                    icon: "tray.and.arrow.down.fill",
                    iconTint: theme.accent,
                    title: "Import workout history",
                    subtitle: "Hevy CSV, common CSV exports, or ForgeFit JSON."
                )
            }
            .buttonStyle(.plain)
            .themedListRow()
        } header: {
            SettingsSectionHeader(title: "Apple Health & Fitness")
        } footer: {
            Text(connected
                ? "Manage exact permissions in the Health app \u{2192} Sharing \u{2192} Apps."
                : "Reads workout metrics and recovery data to drive readiness scores and auto-fill. Writes finished workouts back to Health & Fitness."
            )
        }
    }

    private func connect() {
        connecting = true
        Task {
            _ = await HealthService.shared.requestAuthorization()
            await HealthWorkoutImporter.shared.importRecent(in: modelContext)
            await MainActor.run {
                connected = HealthService.shared.isConnected
                connecting = false
                HealthMetricsStore.shared.refresh(force: true)
            }
        }
    }
}
