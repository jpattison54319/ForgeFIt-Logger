import Foundation

/// The user's default warm-up ramp: an ordered list of warm-up sets, each a
/// percentage of the first working set's weight paired with a rep count. The
/// live logger reads this when "Add Warm-up Ramp" is tapped — it decides the
/// warm-up weights off the working set's target, snaps them to the display
/// unit's step, and inserts them above the working sets.
///
/// Reps are fixed per stage (heavier ramp sets take fewer reps); only the
/// weight depends on the working set, so a ramp added before the working
/// weight is known keeps its reps and fills its weights once that weight
/// exists.
///
/// Defaults mirror the 40/60/80% × 10/6/3 ramp ForgeFit used before it was
/// configurable.
public struct WarmupRampConfig: Codable, Sendable, Equatable {
    public struct Stage: Codable, Sendable, Equatable {
        /// Percentage (5–95) of the first working set's weight.
        public var weightPercent: Int
        /// Target reps for this warm-up set (1–30).
        public var reps: Int

        public init(weightPercent: Int, reps: Int) {
            self.weightPercent = min(95, max(5, weightPercent))
            self.reps = min(30, max(1, reps))
        }
    }

    /// Light→heavy warm-up sets. Never empty; falls back to the default ramp.
    public var stages: [Stage]

    public static let defaultStages: [Stage] = [
        .init(weightPercent: 40, reps: 10),
        .init(weightPercent: 60, reps: 6),
        .init(weightPercent: 80, reps: 3),
    ]
    /// Cap the ramp so the logger never inserts an unwieldy stack of warm-ups.
    public static let maxStages = 6

    public init(stages: [Stage] = defaultStages) {
        // Re-run every stage through the clamping initializer: Codable's
        // synthesized decoder bypasses it, so this is what sanitizes persisted
        // data. An empty list is treated as "use the default ramp".
        let clamped = stages.prefix(Self.maxStages).map { Stage(weightPercent: $0.weightPercent, reps: $0.reps) }
        self.stages = clamped.isEmpty ? Self.defaultStages : Array(clamped)
    }

    public var isDefault: Bool { stages == Self.defaultStages }

    // MARK: - Computation

    /// The snapped display-unit weight for the warm-up at `ordinal` (0-based),
    /// given the working set's weight in the same display unit. Returns nil when
    /// there is no configured stage at that position or nothing to ramp toward.
    public func weight(forStageAt ordinal: Int, topWeightInDisplayUnit top: Double, step: Double) -> Double? {
        guard stages.indices.contains(ordinal), top > 0, step > 0 else { return nil }
        let raw = top * Double(stages[ordinal].weightPercent) / 100
        return max(step, (raw / step).rounded() * step)
    }
}

/// Persistence for `WarmupRampConfig`. Stored as JSON in standard `UserDefaults`
/// under a key registered in `AppPreferenceKeys.backedUp` — a training
/// preference, so it rides the iCloud backup and is cleared on reset. (Contrast
/// `HRZoneConfigStore`, which lives in the app-group suite and is excluded from
/// backup because it encodes health data.)
public enum WarmupRampConfigStore {
    public static let key = "forgefit.warmupRampConfig"

    public static func load(defaults: UserDefaults = .standard) -> WarmupRampConfig {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(WarmupRampConfig.self, from: data) else {
            return WarmupRampConfig()
        }
        // Route through the memberwise init so out-of-range persisted values
        // are re-clamped on the way out.
        return WarmupRampConfig(stages: decoded.stages)
    }

    public static func save(_ config: WarmupRampConfig, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
