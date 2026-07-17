import Foundation

/// Session-scoped aggregation of a live heart-rate stream on the phone,
/// deriving what the Apple Watch's workout session normally provides:
/// running average, maximum, time-in-zone, and a raw sample buffer for the
/// cardio series. Zone attribution mirrors the watch's `tickZone`: whole
/// elapsed seconds between consecutive readings are credited to the zone of
/// the newest reading, with gaps over two minutes discarded as dropouts.
public struct LiveHRAggregator: Sendable {
    public struct HRSample: Sendable, Equatable {
        public let date: Date
        public let bpm: Int

        public init(date: Date, bpm: Int) {
            self.date = date
            self.bpm = bpm
        }
    }

    /// Bounds the buffer for pathological sessions (8 h at 1 Hz).
    private static let maxSamples = 8 * 3600

    public private(set) var latestHR: Int?
    public private(set) var maxHR: Int?
    public private(set) var zoneSeconds: [Int] = [0, 0, 0, 0, 0]
    public private(set) var samples: [HRSample] = []

    private var hrSum = 0
    private var hrCount = 0
    private var lastZoneTick: Date?

    public init() {}

    public var avgHR: Int? {
        hrCount > 0 ? Int((Double(hrSum) / Double(hrCount)).rounded()) : nil
    }

    public mutating func tick(bpm: Int, at date: Date, config: HRZoneConfig) {
        guard bpm > 0 else { return }
        latestHR = bpm
        maxHR = max(maxHR ?? bpm, bpm)
        hrSum += bpm
        hrCount += 1
        if let last = lastZoneTick {
            let elapsed = Int(date.timeIntervalSince(last))
            if elapsed > 0 && elapsed < 120 {
                let zone = config.zone(for: bpm) - 1 // 1...5 -> 0...4
                if (0...4).contains(zone) { zoneSeconds[zone] += elapsed }
            }
        }
        // Only advance the tick for forward-moving timestamps so an
        // out-of-order reading can't wedge future zone attribution.
        if lastZoneTick.map({ date > $0 }) ?? true { lastZoneTick = date }
        if samples.count < Self.maxSamples {
            samples.append(HRSample(date: date, bpm: bpm))
        }
    }

    /// The aggregate in the shape every live-metrics consumer already reads.
    /// Energy and distance stay nil — a bare heart-rate monitor knows neither;
    /// the existing HealthKit window-fill covers them at workout finish.
    public func liveMetrics(asOf date: Date) -> WatchLiveMetrics {
        WatchLiveMetrics(
            heartRate: latestHR,
            avgHR: avgHR,
            maxHR: maxHR,
            hrZoneSeconds: zoneSeconds,
            asOf: date
        )
    }
}
