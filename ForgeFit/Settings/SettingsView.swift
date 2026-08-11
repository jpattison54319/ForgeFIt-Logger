import SwiftUI

/// Settings: connect Apple Health & Fitness (read + write), Apple Watch live-sync
/// status, and units. The Health connection is what powers cardio auto-fill and
/// readiness — so it leads the screen.
struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var watch = WatchLink.shared
    @State private var ble = BLEHeartRateService.shared
    @State private var healthAuthorization = HealthAuthorizationStore.shared
    @State private var showHRMPairing = false
    @State private var showHistoryImporter = false
    @State private var showExportSheet = false
    @State private var showCommunityDeletionSheet = false
    @State private var showResetSheet = false

    var body: some View {
        NavigationStack {
            List {
                SettingsHeroSection(
                    healthConnected: healthAuthorization.state.isConnected,
                    watchPaired: watch.isPaired,
                    hrmConnected: ble.state == .connected
                )
                SettingsAppearanceSection()
                SettingsHealthSection(
                    showHistoryImporter: $showHistoryImporter
                )
                SettingsWatchSection()
                SettingsHRMSection(showHRMPairing: $showHRMPairing)
                SettingsTrainingSection()
                SettingsUnitsSection()
                SettingsEquipmentSection()
                SettingsDataSection(
                    showExportSheet: $showExportSheet,
                    showCommunityDeletionSheet: $showCommunityDeletionSheet,
                    showResetSheet: $showResetSheet
                )
                SettingsAboutSection()
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.bodyStrong)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .heartRateZones:
                    HRZoneSettingsView()
                case .warmupRamp:
                    WarmupRampSettingsView()
                case .platesAndBars:
                    PlatesAndBarsDetailView()
                case .reminders:
                    RemindersDetailView()
                case .yogaGuidance:
                    YogaGuidanceSettingsView()
                case .iCloudBackup:
                    BackupSettingsView()
                case .privacyPolicy:
                    PrivacyPolicyView()
                }
            }
        }
        .sheet(isPresented: $showHistoryImporter) {
            WorkoutHistoryImportView()
        }
        .sheet(isPresented: $showHRMPairing) {
            HRMPairingSheet()
        }
        .sheet(isPresented: $showExportSheet) {
            ExportDataSheet()
        }
        .sheet(isPresented: $showCommunityDeletionSheet) {
            SocialDeleteProfileSheet(allowsLegacyDeletion: true)
        }
        .sheet(isPresented: $showResetSheet) {
            ResetDataSheet {
                showResetSheet = false
                dismiss()
            }
        }
        .onAppear {
            watch.activate()
            ble.reconnectIfRemembered()
            healthAuthorization.refresh()
        }
    }
}
