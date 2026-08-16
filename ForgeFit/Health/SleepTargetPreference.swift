import Foundation

/// The user's explicit sleep-duration target. It stays local because it is a
/// personal health preference and must not enter ForgeFit's training backup.
enum SleepTargetPreference {
    static let key = "sleepTargetMinutes"
    static let defaultMinutes = 8 * 60
    static let allowedMinutes = 5 * 60 ... 12 * 60
    static let incrementMinutes = 15

    static func load(from defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultMinutes }
        return normalized(defaults.integer(forKey: key))
    }

    static func save(_ minutes: Int, to defaults: UserDefaults = .standard) {
        defaults.set(normalized(minutes), forKey: key)
    }

    static func normalized(_ minutes: Int) -> Int {
        let clamped = min(max(minutes, allowedMinutes.lowerBound), allowedMinutes.upperBound)
        let steps = Double(clamped - allowedMinutes.lowerBound) / Double(incrementMinutes)
        return allowedMinutes.lowerBound + Int(steps.rounded()) * incrementMinutes
    }

    static func applying(
        _ minutes: Int,
        to metrics: [RecoveryEngine.DailyHealthMetric]
    ) -> [RecoveryEngine.DailyHealthMetric] {
        let target = normalized(minutes)
        return metrics.map { metric in
            var updated = metric
            updated.sleepNeedMinutes = target
            return updated
        }
    }
}
