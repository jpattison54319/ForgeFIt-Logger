import SwiftUI

/// Settings: connect Apple Health & Fitness (read + write), Apple Watch live-sync
/// status, and units. The Health connection is what powers cardio auto-fill and
/// readiness — so it leads the screen.
struct SettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var watch = WatchLink.shared
    @State private var ble = BLEHeartRateService.shared
    @State private var connected = HealthService.shared.isConnected
    @State private var connecting = false
    @State private var showHRMPairing = false
    @State private var showHistoryImporter = false
    @State private var showExportSheet = false
    @State private var showResetSheet = false

    var body: some View {
        NavigationStack {
            List {
                SettingsHeroSection(
                    healthConnected: connected,
                    watchPaired: watch.isPaired,
                    hrmConnected: ble.state == .connected
                )
                SettingsAppearanceSection()
                SettingsHealthSection(
                    connected: $connected,
                    connecting: $connecting,
                    showHistoryImporter: $showHistoryImporter
                )
                SettingsWatchSection()
                SettingsHRMSection(showHRMPairing: $showHRMPairing)
                SettingsTrainingSection()
                SettingsUnitsSection()
                SettingsEquipmentSection()
                SettingsDataSection(showExportSheet: $showExportSheet, showResetSheet: $showResetSheet)
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
        .sheet(isPresented: $showResetSheet) {
            ResetDataSheet {
                showResetSheet = false
                dismiss()
            }
        }
        .onAppear {
            watch.activate()
            ble.reconnectIfRemembered()
            connected = HealthService.shared.isConnected
        }
    }
}
