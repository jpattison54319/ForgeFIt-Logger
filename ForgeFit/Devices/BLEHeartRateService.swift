import CoreBluetooth
import ForgeCore
import Foundation
import Observation

/// Connects to standard Bluetooth heart-rate monitors (GATT service 0x180D):
/// a Garmin watch in Broadcast Heart Rate mode, Polar/Wahoo straps, etc.
/// Readings feed `LiveMetricsHub`, which arbitrates against the Apple Watch
/// stream. One monitor is remembered per phone (UserDefaults — hardware
/// pairing is device-local and must not ride CloudKit to the user's iPad);
/// connects are re-issued on drops, so the app latches on whenever the user
/// enables broadcast on their watch.
@MainActor
@Observable
final class BLEHeartRateService: NSObject {
    static let shared = BLEHeartRateService()

    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting
        case connected
        /// Lost the link (broadcast stopped, out of range); a pending
        /// connect request will latch on when the monitor reappears.
        case reconnecting
    }

    struct DiscoveredMonitor: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    private nonisolated static let heartRateService = CBUUID(string: "180D")
    private nonisolated static let heartRateMeasurement = CBUUID(string: "2A37")
    private static let rememberedIDKey = "blehrm.peripheralID"
    private static let rememberedNameKey = "blehrm.peripheralName"

    private(set) var state: ConnectionState = .idle
    private(set) var discovered: [DiscoveredMonitor] = []
    private(set) var bluetoothUnavailable = false
    private(set) var lastReadingAt: Date?
    /// Set when a user-initiated pairing attempt fails or times out, so the
    /// pairing sheet can stop its spinner and say so. Cleared on the next
    /// connect attempt.
    private(set) var lastConnectFailed = false

    var rememberedName: String? {
        UserDefaults.standard.string(forKey: Self.rememberedNameKey)
    }
    var hasRememberedMonitor: Bool { rememberedID != nil }

    private var rememberedID: UUID? {
        UserDefaults.standard.string(forKey: Self.rememberedIDKey).flatMap(UUID.init)
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var wantsScan = false
    @ObservationIgnored private var wantsAutoConnect = false
    /// The monitor a user just tapped in the pairing sheet. It is only
    /// persisted as the remembered monitor AFTER `didConnect` — persisting on
    /// tap made Settings show a never-connected device as "paired". The
    /// timeout is candidate-scoped so it can never strangle the standing
    /// remembered-monitor auto-reconnect loop.
    @ObservationIgnored private var pairingCandidate: DiscoveredMonitor?
    @ObservationIgnored private var pairingTimeoutTask: Task<Void, Never>?

    // MARK: - Public API

    /// Scan for nearby monitors (pairing sheet). Creating the central manager
    /// triggers the system Bluetooth permission prompt, so it is deferred to
    /// the first user-initiated action rather than app launch.
    func startScanning() {
        wantsScan = true
        discovered = []
        let central = ensureCentral()
        if central.state == .poweredOn {
            // Scanning is allowed while connected (pairing a replacement);
            // don't demote the connected state.
            if state != .connected { state = .scanning }
            central.scanForPeripherals(withServices: [Self.heartRateService])
        }
    }

    func stopScanning() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning {
            state = peripheral?.state == .connected ? .connected : .idle
        }
    }

    /// Connect to a monitor from the scan list, releasing any previously
    /// connected monitor first. The monitor is remembered only once the
    /// connection actually succeeds (`didConnect`); a 15 s timeout surfaces
    /// failure instead of spinning forever.
    func connect(to monitor: DiscoveredMonitor) {
        stopScanning()
        lastConnectFailed = false
        if let peripheral, peripheral.identifier != monitor.id {
            central?.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
        }
        pairingCandidate = monitor
        startPairingTimeout(for: monitor.id)
        connectPeripheral(id: monitor.id)
    }

    /// Re-issue a connect for the remembered monitor. Safe to call anytime
    /// (launch, workout start); no-op without a remembered monitor or while
    /// already connecting/connected. iOS connect requests never time out, so
    /// this doubles as "attach whenever broadcast turns on".
    func reconnectIfRemembered() {
        guard hasRememberedMonitor, state == .idle || state == .reconnecting else { return }
        wantsAutoConnect = true
        let central = ensureCentral()
        if central.state == .poweredOn {
            connectRemembered()
        }
    }

    /// Drop and forget the remembered monitor.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.rememberedIDKey)
        UserDefaults.standard.removeObject(forKey: Self.rememberedNameKey)
        wantsAutoConnect = false
        clearPairingCandidate()
        lastConnectFailed = false
        if let peripheral, let central {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        lastReadingAt = nil
        state = .idle
    }

    // MARK: - Internals

    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        let manager = CBCentralManager(delegate: self, queue: nil)
        central = manager
        return manager
    }

    private func connectRemembered() {
        guard let id = rememberedID else { return }
        connectPeripheral(id: id)
    }

    private func connectPeripheral(id: UUID) {
        guard let central, central.state == .poweredOn else { return }
        guard let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            // Not known to the system anymore; a fresh scan will find it.
            if pairingCandidate?.id == id {
                failPairing()
            } else {
                state = .idle
            }
            return
        }
        peripheral = target
        target.delegate = self
        if state != .reconnecting { state = .connecting }
        central.connect(target)
    }

    /// Routes a failed/ended connection: a pairing candidate surfaces as a
    /// pairing failure; a remembered monitor enters the reconnect loop.
    private func handleDisconnect(of peripheral: CBPeripheral) {
        if let candidate = pairingCandidate, candidate.id == peripheral.identifier {
            failPairing()
            return
        }
        handleDrop()
    }

    /// A remembered monitor dropped (broadcast stopped, out of range) — keep
    /// a pending connect open so it re-attaches the moment broadcast returns.
    private func handleDrop() {
        lastReadingAt = nil
        guard hasRememberedMonitor else {
            peripheral = nil
            state = .idle
            return
        }
        state = .reconnecting
        connectRemembered()
    }

    // MARK: - Pairing candidate lifecycle

    /// A user-initiated pairing attempt failed or timed out: surface it,
    /// then fall back to the remembered monitor (if any) — a failed pairing
    /// with a NEW device must not kill the standing auto-reconnect.
    private func failPairing() {
        clearPairingCandidate()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        lastReadingAt = nil
        lastConnectFailed = true
        if hasRememberedMonitor {
            state = .reconnecting
            connectRemembered()
        } else {
            state = .idle
        }
    }

    private func startPairingTimeout(for id: UUID) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            // Candidate-scoped: only kill THIS attempt, never a later one or
            // the remembered-monitor reconnect loop.
            guard self.pairingCandidate?.id == id else { return }
            self.failPairing()
        }
    }

    private func clearPairingCandidate() {
        pairingCandidate = nil
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEHeartRateService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                bluetoothUnavailable = false
                if wantsScan {
                    if state != .connected { state = .scanning }
                    central.scanForPeripherals(withServices: [Self.heartRateService])
                } else if wantsAutoConnect {
                    connectRemembered()
                }
            case .poweredOff, .unauthorized, .unsupported:
                bluetoothUnavailable = true
                state = .idle
                lastReadingAt = nil
            default:
                break
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let monitor = DiscoveredMonitor(
            id: peripheral.identifier,
            name: peripheral.name
                ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? "Heart Rate Monitor",
            rssi: RSSI.intValue
        )
        Task { @MainActor in
            if let index = discovered.firstIndex(where: { $0.id == monitor.id }) {
                discovered[index] = monitor
            } else {
                discovered.append(monitor)
            }
            discovered.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            if let candidate = pairingCandidate {
                guard candidate.id == peripheral.identifier else {
                    // A stale earlier attempt latched on after the user tapped
                    // a different monitor — release it, the candidate wins.
                    central.cancelPeripheralConnection(peripheral)
                    return
                }
                // NOW it's proven reachable — remember it. Persisting on tap
                // made Settings show never-connected devices as paired.
                UserDefaults.standard.set(candidate.id.uuidString, forKey: Self.rememberedIDKey)
                UserDefaults.standard.set(candidate.name, forKey: Self.rememberedNameKey)
                clearPairingCandidate()
            } else if peripheral.identifier != rememberedID {
                // Stray connect for a monitor we no longer care about.
                central.cancelPeripheralConnection(peripheral)
                return
            }
            self.peripheral = peripheral
            state = .connected
            peripheral.discoverServices([Self.heartRateService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in handleDisconnect(of: peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in handleDisconnect(of: peripheral) }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEHeartRateService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else { return }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else { return }
        peripheral.setNotifyValue(true, for: characteristic)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurement,
              let data = characteristic.value,
              let measurement = HeartRateMeasurement.parse(data) else { return }
        Task { @MainActor in
            lastReadingAt = Date()
            LiveMetricsHub.shared.updateFromBLE(heartRate: measurement.bpm)
        }
    }
}
