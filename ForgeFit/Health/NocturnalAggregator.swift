import Foundation

/// Buckets overnight biometric samples into per-night nocturnal aggregates,
/// keyed by the calendar day the sleep *ended* (last night's sleep → today's
/// readiness). Pure value-type math so it can be unit-tested without HealthKit.
///
/// Why nocturnal: sleeping HRV and heart rate are the validated recovery
/// window — supine, stable, and free of daytime posture / stress / caffeine
/// confounds (Plews et al. 2013, Sports Med; Buchheit 2014, Front Physiol).
/// Apple's all-day HRV mean and daytime-derived resting HR are noisier proxies.
nonisolated enum NocturnalAggregator {
    /// A merged sleep period, tagged with the morning it belongs to.
    struct SleepWindow: Equatable, Sendable {
        let start: Date
        let end: Date
        /// `startOfDay(end)` — the readiness day this night feeds.
        let day: Date
    }

    /// Sorted-window point index: replaces the O(windows) `first(where:)`
    /// scan that every sample used to pay with an O(log n) lookup.
    /// `windows(fromAsleepSegments:)` merges until gaps exceed the tolerance,
    /// so produced windows are pairwise disjoint: each date falls inside at
    /// most one window, which makes the index exactly equivalent to the scan
    /// it replaces. Bounds are inclusive (`>= start && <= end`), matching the
    /// scan's semantics.
    struct SleepWindowIndex: Equatable {
        let windows: [SleepWindow]

        init(_ windows: [SleepWindow]) {
            self.windows = windows.sorted { $0.start < $1.start }
        }

        var count: Int { windows.count }

        /// The window containing `date`, or nil when it lies in a gap.
        func window(containing date: Date) -> SleepWindow? {
            var low = 0
            var high = windows.count - 1
            while low <= high {
                let mid = low + (high - low) / 2
                let window = windows[mid]
                if date < window.start {
                    high = mid - 1
                } else if date > window.end {
                    low = mid + 1
                } else {
                    return window
                }
            }
            return nil
        }
    }

    struct NightlyMetric: Equatable, Sendable {
        var hrv: Double?
        var sleepingHR: Int?
        var hrvSampleCount: Int
        var hrvOccupiedBinCount: Int
        var hrvSampleSpanMinutes: Int
        /// Nocturnal HR sample count — coverage of the sleep window, used to
        /// tell a real short night (dense samples) from a partial-wear fragment.
        var sleepingHRSampleCount: Int
        var sleepingHROccupiedBinCount: Int
        var sleepingHRSampleSpanMinutes: Int
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

    static let minHRVBins = 4
    static let minSleepingHRBins = 6
    static let minimumSpanMinutes = 180

    /// Time-balanced nightly summaries keyed by the day sleep ended. HRV uses
    /// the median of hourly log-median bins; heart rate uses the median of
    /// 30-minute median bins. Equal bin weighting prevents a dense burst of
    /// samples from dominating the entire night.
    static func nightly(
        windows: [SleepWindow],
        hrv: [(date: Date, value: Double)],
        hr: [(date: Date, bpm: Int)]
    ) -> [Date: NightlyMetric] {
        guard !windows.isEmpty else { return [:] }
        let index = SleepWindowIndex(windows)
        var hrvByDay: [Date: [(date: Date, value: Double)]] = [:]
        var hrByDay: [Date: [(date: Date, value: Int)]] = [:]

        for sample in hrv {
            guard !Task.isCancelled else { return [:] }
            if let window = index.window(containing: sample.date) {
                guard sample.value > 0 else { continue }
                hrvByDay[window.day, default: []].append(sample)
            }
        }
        for sample in hr {
            guard !Task.isCancelled else { return [:] }
            if let window = index.window(containing: sample.date) {
                guard sample.bpm > 0 else { continue }
                hrByDay[window.day, default: []].append((sample.date, sample.bpm))
            }
        }

        var out: [Date: NightlyMetric] = [:]
        for day in Set(hrvByDay.keys).union(hrByDay.keys) {
            let hrvSamples = hrvByDay[day] ?? []
            let hrSamples = hrByDay[day] ?? []
            let hrvBins = binnedValues(
                hrvSamples.map { ($0.date, log($0.value)) },
                binWidth: 60 * 60
            )
            let hrBins = binnedValues(
                hrSamples.map { ($0.date, Double($0.value)) },
                binWidth: 30 * 60
            )
            let hrvSpan = sampleSpanMinutes(hrvSamples.map(\.date))
            let hrSpan = sampleSpanMinutes(hrSamples.map(\.date))
            let eligibleHRV = hrvBins.count >= minHRVBins && hrvSpan >= minimumSpanMinutes
            let eligibleHR = hrBins.count >= minSleepingHRBins && hrSpan >= minimumSpanMinutes
            out[day] = NightlyMetric(
                hrv: eligibleHRV ? median(hrvBins).map(exp) : nil,
                sleepingHR: eligibleHR ? median(hrBins).map { Int($0.rounded()) } : nil,
                hrvSampleCount: hrvSamples.count,
                hrvOccupiedBinCount: hrvBins.count,
                hrvSampleSpanMinutes: hrvSpan,
                sleepingHRSampleCount: hrSamples.count,
                sleepingHROccupiedBinCount: hrBins.count,
                sleepingHRSampleSpanMinutes: hrSpan
            )
        }
        return out
    }

    /// Bundle IDs of nocturnal HR samples grouped by the morning the
    /// containing sleep window ended — the value backing
    /// `DailyHealthMetric.sleepingHRSourceBundleID`. One indexed pass per
    /// sample; the prebucketed replacement for the per-day × per-sample ×
    /// per-window scan that used to re-filter every sample for every day.
    /// Mirrors the old filter exactly: EVERY windowed sample counts
    /// (including `bpm == 0` readings — only nightly *binning* skips those),
    /// and samples outside every window are ignored.
    static func sourcesByDay(
        windows: [SleepWindow],
        hr: [(date: Date, sourceBundleID: String)]
    ) -> [Date: [String]] {
        guard !hr.isEmpty else { return [:] }
        let index = SleepWindowIndex(windows)
        var byDay: [Date: [String]] = [:]
        for sample in hr {
            // Cancellation yields nothing, never a partial bucket — the caller
            // treats a cancelled run as "no data", not as a shortened night.
            guard !Task.isCancelled else { return [:] }
            if let window = index.window(containing: sample.date) {
                byDay[window.day, default: []].append(sample.sourceBundleID)
            }
        }
        return byDay
    }

    private static func binnedValues(
        _ samples: [(date: Date, value: Double)],
        binWidth: TimeInterval
    ) -> [Double] {
        let groups = Dictionary(grouping: samples) {
            Int(floor($0.date.timeIntervalSince1970 / binWidth))
        }
        return groups.keys.sorted().compactMap { key in
            median(groups[key, default: []].map(\.value))
        }
    }

    private static func sampleSpanMinutes(_ dates: [Date]) -> Int {
        guard let first = dates.min(), let last = dates.max() else { return 0 }
        return Int(last.timeIntervalSince(first) / 60)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }
}
