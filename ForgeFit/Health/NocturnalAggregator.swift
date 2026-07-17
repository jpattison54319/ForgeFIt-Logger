import Foundation

/// Buckets overnight biometric samples into per-night nocturnal aggregates,
/// keyed by the calendar day the sleep *ended* (last night's sleep → today's
/// readiness). Pure value-type math so it can be unit-tested without HealthKit.
///
/// Why nocturnal: sleeping HRV and heart rate are the validated recovery
/// window — supine, stable, and free of daytime posture / stress / caffeine
/// confounds (Plews et al. 2013, Sports Med; Buchheit 2014, Front Physiol).
/// Apple's all-day HRV mean and daytime-derived resting HR are noisier proxies.
enum NocturnalAggregator {
    /// A merged sleep period, tagged with the morning it belongs to.
    struct SleepWindow: Equatable {
        let start: Date
        let end: Date
        /// `startOfDay(end)` — the readiness day this night feeds.
        let day: Date
    }

    struct NightlyMetric: Equatable {
        var hrv: Double?
        var sleepingHR: Int?
        var hrvSampleCount: Int
        /// Nocturnal HR sample count — coverage of the sleep window, used to
        /// tell a real short night (dense samples) from a partial-wear fragment.
        var sleepingHRSampleCount: Int
    }

    /// Merge asleep segments into whole sleep windows, stitching brief
    /// awakenings (`gapTolerance`, default 60 min) so one night is one window.
    static func windows(
        fromAsleepSegments segments: [(start: Date, end: Date)],
        calendar: Calendar,
        gapTolerance: TimeInterval = 60 * 60
    ) -> [SleepWindow] {
        let sorted = segments.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return [] }
        var merged: [(start: Date, end: Date)] = []
        for segment in sorted {
            if let last = merged.last, segment.start.timeIntervalSince(last.end) <= gapTolerance {
                merged[merged.count - 1].end = max(last.end, segment.end)
                merged[merged.count - 1].start = min(last.start, segment.start)
            } else {
                merged.append(segment)
            }
        }
        return merged.map { SleepWindow(start: $0.start, end: $0.end, day: calendar.startOfDay(for: $0.end)) }
    }

    /// Below this many overnight HR samples, a "sleeping HR" is really just
    /// one or two spot readings — a single spurious sample (restless moment,
    /// bad optical contact) would define the whole night. Sparse sources like
    /// Garmin's smart recording synced through Apple Health still clear this
    /// easily (a sample every 5–15 min is dozens per night).
    static let minSleepingHRSamples = 3

    /// Per-night nocturnal HRV (mean, ms) and sleeping HR (mean, bpm), keyed by
    /// readiness day. Samples are attributed to the window that contains them;
    /// windows sharing a day are pooled.
    static func nightly(
        windows: [SleepWindow],
        hrv: [(date: Date, value: Double)],
        hr: [(date: Date, bpm: Int)]
    ) -> [Date: NightlyMetric] {
        guard !windows.isEmpty else { return [:] }
        var hrvByDay: [Date: [Double]] = [:]
        var hrByDay: [Date: [Int]] = [:]

        for sample in hrv {
            if let window = windows.first(where: { sample.date >= $0.start && sample.date <= $0.end }) {
                hrvByDay[window.day, default: []].append(sample.value)
            }
        }
        for sample in hr {
            if let window = windows.first(where: { sample.date >= $0.start && sample.date <= $0.end }) {
                hrByDay[window.day, default: []].append(sample.bpm)
            }
        }

        var out: [Date: NightlyMetric] = [:]
        for day in Set(hrvByDay.keys).union(hrByDay.keys) {
            let hrvValues = hrvByDay[day] ?? []
            let hrValues = hrByDay[day] ?? []
            out[day] = NightlyMetric(
                hrv: hrvValues.isEmpty ? nil : hrvValues.reduce(0, +) / Double(hrvValues.count),
                sleepingHR: hrValues.count >= minSleepingHRSamples
                    ? Int((Double(hrValues.reduce(0, +)) / Double(hrValues.count)).rounded())
                    : nil,
                hrvSampleCount: hrvValues.count,
                sleepingHRSampleCount: hrValues.count
            )
        }
        return out
    }
}
