import Foundation

/// The user's heart-rate zone model: a max HR plus the fractional upper bounds
/// of zones 1–4 (zone 5 runs to max). Lives in ForgeCore so the phone (zone
/// bars, interval alerts), the watch (live time-in-zone + zone guard), and the
/// widgets all classify HR against the same personalized boundaries.
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
        let pct = Double(hr) / Double(max(1, maxHR))
        for (index, bound) in zoneUpperBounds.enumerated() where pct < bound {
            return index + 1
        }
        return 5
    }

    /// Inclusive lower bpm bound of a zone (zone 1 starts at 0).
    public func lowerBPM(forZone zone: Int) -> Int {
        guard zone > 1 else { return 0 }
        let index = zone - 2 // zone 2 -> bounds[0]
        guard zoneUpperBounds.indices.contains(index) else { return 0 }
        return Int((zoneUpperBounds[index] * Double(maxHR)).rounded())
    }

    /// Upper bpm bound of a zone (zone 5 runs to max HR).
    public func upperBPM(forZone zone: Int) -> Int {
        guard zone < 5 else { return maxHR }
        let index = zone - 1 // zone 1 -> bounds[0]
        guard zoneUpperBounds.indices.contains(index) else { return maxHR }
        return Int((zoneUpperBounds[index] * Double(maxHR)).rounded())
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
