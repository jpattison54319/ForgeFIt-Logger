import ForgeCore
import Foundation
import Observation

/// The single source of truth for live workout metrics on the phone,
/// arbitrating between the Apple Watch stream (preferred) and a paired
/// Bluetooth heart-rate monitor — a Garmin watch in Broadcast Heart Rate
/// mode, a chest strap, etc.
///
/// The watch owns the feed while its updates are fresh; BLE readings always
/// feed the session aggregator (avg/max/time-in-zone/sample buffer) but only
/// publish once the watch has gone quiet, so a user wearing both never sees
/// the number flip-flop between sources.
@MainActor
@Observable
final class LiveMetricsHub {
    static let shared = LiveMetricsHub()

    enum Source {
        case appleWatch
        case bluetoothHRM
        case none
    }

    /// Rolling metrics from whichever source currently owns the feed — shown
    /// live in the logger and stamped onto the workout at finish.
    private(set) var liveMetrics: WatchLiveMetrics?
    private(set) var source: Source = .none

    /// How recent the watch's last metrics must be for it to keep the feed.
    /// Watch pushes arrive every 1–5 s while streaming, so 15 s of silence
    /// means the session ended or the watch came off.
    private static let watchFreshWindow: TimeInterval = 15

    /// Session-scoped BLE aggregation; nil outside a workout. Exposed so the
    /// finish pipeline can persist the buffered samples.
    @ObservationIgnored private(set) var sessionAggregator: LiveHRAggregator?
    @ObservationIgnored private var zoneConfig = HRZoneConfigStore.load()

    /// Start aggregating BLE readings for a workout. Idempotent per workout —
    /// callers may invoke it again on relaunch into an active session.
    func beginSession() {
        zoneConfig = HRZoneConfigStore.load()
        if sessionAggregator == nil {
            sessionAggregator = LiveHRAggregator()
        }
    }

    /// Stop aggregating and hand back the final BLE aggregate (nil when no
    /// BLE readings arrived during the session).
    @discardableResult
    func endSession() -> LiveHRAggregator? {
        let aggregator = sessionAggregator
        sessionAggregator = nil
        liveMetrics = nil
        source = .none
        return aggregator
    }

    /// Zone boundaries changed in Settings; re-read for zone attribution.
    func reloadZoneConfig() {
        zoneConfig = HRZoneConfigStore.load()
    }

    func updateFromWatch(_ metrics: WatchLiveMetrics) {
        liveMetrics = metrics
        source = .appleWatch
    }

    func updateFromBLE(heartRate bpm: Int, at date: Date = Date()) {
        sessionAggregator?.tick(bpm: bpm, at: date, config: zoneConfig)
        if source == .appleWatch, let asOf = liveMetrics?.asOf,
           date.timeIntervalSince(asOf) < Self.watchFreshWindow {
            return
        }
        if let sessionAggregator {
            liveMetrics = sessionAggregator.liveMetrics(asOf: date)
        } else {
            // Outside a workout (e.g. the zone-test live readout) there is
            // nothing to aggregate — publish the raw reading.
            liveMetrics = WatchLiveMetrics(heartRate: bpm, asOf: date)
        }
        source = .bluetoothHRM
    }

    func clearLiveMetrics() {
        liveMetrics = nil
        source = .none
    }

    // MARK: - Buffered BLE samples

    /// Buffered BLE readings inside a window — feeds the cardio series and
    /// HealthKit writes. BLE heart rate isn't in HealthKit until the workout
    /// finishes, so segment-level consumers read the buffer directly.
    func bleSamples(from start: Date, to end: Date) -> [LiveHRAggregator.HRSample] {
        sessionAggregator?.samples.filter { $0.date >= start && $0.date <= end } ?? []
    }

    /// Avg/max over the buffered BLE readings in a window — the fill for
    /// per-segment stats when HealthKit's window query comes back empty.
    /// Capture this synchronously before deferring work: `endSession()`
    /// drops the buffer.
    func bleWindowStats(from start: Date, to end: Date) -> (avgHR: Int, maxHR: Int)? {
        let bpms = bleSamples(from: start, to: end).map(\.bpm)
        guard let maxBPM = bpms.max() else { return nil }
        let avg = Int((Double(bpms.reduce(0, +)) / Double(bpms.count)).rounded())
        return (avgHR: avg, maxHR: maxBPM)
    }
}
