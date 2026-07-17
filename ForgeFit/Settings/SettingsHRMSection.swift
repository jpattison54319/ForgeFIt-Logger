import SwiftUI

/// Bluetooth heart-rate monitor section: status, pairing, and forget actions.
struct SettingsHRMSection: View {
    @Environment(\.theme) private var theme
    @State private var ble = BLEHeartRateService.shared

    @Binding var showHRMPairing: Bool
    @State private var showForgetHRMConfirm = false

    var body: some View {
        Section {
            SettingsRow(icon: "sensor.tag.radiowaves.forward.fill", iconTint: theme.danger, title: ble.rememberedName ?? "No monitor paired", subtitle: hrmStatusText) {
                if ble.state == .connected {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(theme.success)
                }
            }
            .themedListRow()

            Button {
                showHRMPairing = true
            } label: {
                SettingsRowLabel(title: ble.hasRememberedMonitor ? "Pair a different monitor" : "Pair a monitor")
            }
            .buttonStyle(.plain)
            .themedListRow()

            if ble.hasRememberedMonitor {
                Button(role: .destructive) {
                    showForgetHRMConfirm = true
                } label: {
                    SettingsRowLabel(title: "Forget Monitor", subtitle: ble.rememberedName)
                }
                .buttonStyle(.plain)
                .themedListRow()
                .confirmationDialog(
                    "Forget \(ble.rememberedName ?? "this monitor")?",
                    isPresented: $showForgetHRMConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Forget Monitor", role: .destructive) { ble.forget() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("ForgeFit stops connecting to it automatically. You can pair it again anytime.")
                }
            }
        } header: {
            SettingsSectionHeader(title: "Heart Rate Monitor")
        } footer: {
            Text("Pair a Garmin watch (Broadcast Heart Rate mode), Polar, Wahoo, or any Bluetooth chest strap for live heart rate, zones & effort.")
        }
    }

    private var hrmStatusText: String {
        if ble.bluetoothUnavailable { return "Bluetooth is off" }
        switch ble.state {
        case .connected: return "Connected"
        case .connecting: return "Connecting\u{2026}"
        case .reconnecting: return "Waiting for broadcast\u{2026}"
        case .scanning: return "Scanning\u{2026}"
        case .idle: return ble.hasRememberedMonitor ? "Paired \u{2014} will connect when broadcasting" : "Not paired"
        }
    }
}
