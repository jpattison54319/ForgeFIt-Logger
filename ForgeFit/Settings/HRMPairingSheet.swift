import SwiftUI

/// Scan-and-pair sheet for Bluetooth heart-rate monitors: Garmin watches in
/// Broadcast Heart Rate mode, Polar/Wahoo watches and straps, and any other
/// standard BLE monitor. One monitor is remembered; ForgeFit reconnects to it
/// automatically whenever it's broadcasting.
struct HRMPairingSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var ble = BLEHeartRateService.shared
    @State private var connectingID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    garminHowTo
                    monitorList
                    footnotes
                }
                .padding(.horizontal, Space.lg)
                .padding(.vertical, Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Pair a Heart Rate Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear { ble.startScanning() }
        .onDisappear { ble.stopScanning() }
        .onChange(of: ble.state) { _, state in
            // Paired and connected — done here.
            if state == .connected { dismiss() }
        }
        .onChange(of: ble.lastConnectFailed) { _, failed in
            // Stop the row spinner so the failure card isn't contradicted by
            // a monitor that still looks like it's connecting.
            if failed { connectingID = nil }
        }
    }

    private var garminHowTo: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Using a Garmin watch?")
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Label("Turn on heart-rate broadcast", systemImage: "dot.radiowaves.left.and.right")
                        .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("On the watch, open Settings → Sensors & Accessories → Wrist Heart Rate → Broadcast Heart Rate (on many models it's also in the controls menu). Enable Broadcast During Activity to start broadcasting automatically with every activity.")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Polar and Wahoo watches, chest straps, and armbands broadcast by default — just wear them.")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var monitorList: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                SectionHeader("Nearby monitors")
                ProgressView().controlSize(.small)
            }
            if ble.lastConnectFailed {
                Card {
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(theme.warmup)
                        Text("Couldn't connect — make sure the monitor is broadcasting.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if ble.bluetoothUnavailable {
                Card {
                    Label("Bluetooth is off or unavailable. Turn it on in Control Center to scan.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            } else if ble.discovered.isEmpty {
                Card {
                    Text("Searching… make sure your monitor is on and broadcasting.")
                        .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            } else {
                ForEach(ble.discovered) { monitor in
                    Button {
                        connectingID = monitor.id
                        ble.connect(to: monitor)
                    } label: {
                        Card {
                            HStack(spacing: Space.md) {
                                Image(systemName: "heart.fill")
                                    .font(.bodyStrong)
                                    .foregroundStyle(theme.danger)
                                    .frame(width: 24)
                                Text(monitor.name)
                                    .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                Spacer()
                                if connectingID == monitor.id {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "cellularbars", variableValue: signalLevel(monitor.rssi))
                                        .font(.system(size: 15))
                                        .foregroundStyle(theme.textSecondary)
                                        .accessibilityLabel("Signal strength")
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Connect to \(monitor.name)")
                }
            }
        }
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("A monitor connects to one app or device at a time — if it doesn't appear, disconnect it elsewhere first.")
            Text("Broadcasting uses extra watch battery, and your Apple Watch still takes priority whenever it's streaming.")
        }
        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Rough RSSI → 0...1 signal level (−90 dBm weak, −40 dBm strong).
    private func signalLevel(_ rssi: Int) -> Double {
        min(1, max(0, (Double(rssi) + 90) / 50))
    }
}
