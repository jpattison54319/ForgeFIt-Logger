import SwiftData
import SwiftUI

/// Apple Health connection section: connect/disconnect status, write toggle,
/// and workout history import.
struct SettingsHealthSection: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    @Binding var showHistoryImporter: Bool

    @AppStorage("healthWriteEnabled") private var healthWriteEnabled = true
    @State private var authorization = HealthAuthorizationStore.shared

    var body: some View {
        Section {
            if authorization.state.isConnected {
                SettingsRow(icon: "heart.fill", iconTint: theme.danger, title: "Apple Health", subtitle: "Connected") {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.success)
                }
                .themedListRow()
            } else if authorization.state.requiresPermissionReview {
                Button {
                    HealthAuthorizationRecovery.openSettings()
                } label: {
                    SettingsRowLabel(
                        icon: "gearshape.fill",
                        iconTint: theme.danger,
                        title: "Review Apple Health Access",
                        subtitle: "Settings, or Health → Sharing → Apps → ForgeFit"
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .accessibilityIdentifier("settings-open-health-access")
            } else {
                Button {
                    connect()
                } label: {
                    SettingsRowLabel(
                        icon: "heart.fill",
                        iconTint: theme.danger,
                        title: authorization.state.isRequesting
                            ? "Connecting\u{2026}"
                            : authorization.state == .notDetermined
                                ? "Connect Apple Health"
                                : "Try Apple Health Again"
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .disabled(authorization.state.isRequesting || authorization.state == .unavailable)
            }

            if let issue = authorization.state.issueMessage {
                Text(issue)
                    .font(.footnote)
                    .foregroundStyle(authorization.state.requiresPermissionReview ? theme.textPrimary : theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .themedListRow()
                    .accessibilityIdentifier("settings-health-authorization-issue")
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
            Text(authorization.state.isConnected
                ? "Manage exact permissions in the Health app \u{2192} Sharing \u{2192} Apps."
                : "Reads workout metrics and recovery data to drive readiness scores and auto-fill. Writes finished workouts back to Health & Fitness."
            )
        }
        .onAppear { authorization.refresh() }
    }

    private func connect() {
        Task {
            guard await authorization.connect() else { return }
            await HealthWorkoutImporter.shared.importRecent(in: modelContext.container)
            HealthMetricsStore.shared.refresh(force: true)
        }
    }
}
