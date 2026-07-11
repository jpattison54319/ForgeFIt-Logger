import Foundation

/// The user's heart-rate zone model: a max HR plus the fractional upper bounds
/// of zones 1-4 (zone 5 runs to max). When a resting HR is available, the
/// fractions are Karvonen/%HRR values; otherwise they fall back to %HRmax.
/// Lives in ForgeCore so the phone (zone bars, interval alerts), the watch
/// (live time-in-zone + zone guard), and the widgets all classify HR against
/// the same personalized boundaries.
///
/// Defaults mirror the classic 60/70/80/90% model and a max HR of 190, matching
/// the values ForgeFit used before zones were configurable.
public struct HRZoneConfig: Codable, Sendable, Equatable {
    public static let defaultMaxHR = 190
    /// Fractional upper bounds for zones 1–4 (ascending, each in 0...1).
    public static let defaultBounds: [Double] = [0.60, 0.70, 0.80, 0.90]

    public var maxHR: Int
    public var restingHR: Int?
    public var zoneUpperBounds: [Double]

    public init(
        maxHR: Int = defaultMaxHR,
        restingHR: Int? = nil,
        zoneUpperBounds: [Double] = defaultBounds
    ) {
        self.maxHR = max(1, maxHR)
        self.restingHR = restingHR
        // Guard against malformed persisted data: require 4 ascending bounds.
        let sane = zoneUpperBounds.count == 4 && zip(zoneUpperBounds, zoneUpperBounds.dropFirst()).allSatisfy { $0 < $1 }
        self.zoneUpperBounds = sane ? zoneUpperBounds : Self.defaultBounds
    }

    // MARK: - Classification

    /// The zone (1...5) a given heart rate falls in.
    public func zone(for hr: Int) -> Int {
        let fraction = fraction(forBPM: hr)
        for (index, bound) in zoneUpperBounds.enumerated() where fraction < bound {
            return index + 1
        }
        return 5
    }

    public var usesHeartRateReserve: Bool { restingHR != nil }

    /// Converts a fractional zone boundary to BPM using the active basis:
    /// Karvonen/%HRR when resting HR exists, else %HRmax.
    public func bpm(forFraction fraction: Double) -> Int {
        let clamped = max(0, min(1, fraction))
        if let restingHR {
            let reserve = max(1, maxHR - restingHR)
            return Int((Double(restingHR) + clamped * Double(reserve)).rounded())
        }
        return Int((clamped * Double(max(1, maxHR))).rounded())
    }

    /// Converts BPM back to the active zone-boundary fraction.
    public func fraction(forBPM bpm: Int) -> Double {
        if let restingHR {
            return Double(bpm - restingHR) / Double(max(1, maxHR - restingHR))
        }
        return Double(bpm) / Double(max(1, maxHR))
    }

    /// Inclusive lower bpm bound of a zone (zone 1 starts at 0).
    public func lowerBPM(forZone zone: Int) -> Int {
        guard zone > 1 else { return restingHR ?? 0 }
        let index = zone - 2 // zone 2 -> bounds[0]
        guard zoneUpperBounds.indices.contains(index) else { return 0 }
        return bpm(forFraction: zoneUpperBounds[index])
    }

    /// Upper bpm bound of a zone (zone 5 runs to max HR).
    public func upperBPM(forZone zone: Int) -> Int {
        guard zone < 5 else { return maxHR }
        let index = zone - 1 // zone 1 -> bounds[0]
        guard zoneUpperBounds.indices.contains(index) else { return maxHR }
        return bpm(forFraction: zoneUpperBounds[index])
    }

    /// The bpm range for a zone, e.g. 114...133 for Z2 at max 190.
    public func rangeBPM(forZone zone: Int) -> ClosedRange<Int> {
        let low = lowerBPM(forZone: zone)
        return low...max(low, upperBPM(forZone: zone))
    }

    /// Convenience: max HR estimated from age via the classic 220 − age.
    public static func maxHR(forAge age: Int) -> Int {
        max(100, min(220, 220 - age))
    }
}

/// Shared persistence for `HRZoneConfig` in the app-group container so the
/// watch and widget read the same personalized zones the phone writes.
public enum HRZoneConfigStore {
    public static let suiteName = "group.org.xpetsllc.ForgeFit"
    public static let key = "forgefit.hrZoneConfig"

    public static func load(defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) -> HRZoneConfig {
        let store = defaults ?? .standard
        guard let data = store.data(forKey: key),
              let config = try? JSONDecoder().decode(HRZoneConfig.self, from: data) else {
            return HRZoneConfig()
        }
        return config
    }

    public static func save(_ config: HRZoneConfig, defaults: UserDefaults? = UserDefaults(suiteName: suiteName)) {
        let store = defaults ?? .standard
        guard let data = try? JSONEncoder().encode(config) else { return }
        store.set(data, forKey: key)
    }
}
