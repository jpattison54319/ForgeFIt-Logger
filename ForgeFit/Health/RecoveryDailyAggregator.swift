import Foundation

/// Pure, HealthKit-free per-day recovery bucketing: turns one query window
/// of raw recovery samples into `RecoveryEngine`'s daily metrics. This is the
/// exact math that used to live inline in `HealthService.dailyMetrics`.
///
/// Extracted for two reasons:
/// 1. Equivalence — a legacy day × sample × window scan can be recreated in
///    tests and proven bit-identical against the prebucketed path.
/// 2. Execution isolation — the heavy CPU pass (sorting, bucketing, binning,
///    source dominance) is a `Sendable` pure function, so `HealthService`
///    can run it through `CancellableDetachedWork` instead of inheriting a
///    MainActor caller.
///
/// Window membership everywhere uses the same inclusive semantics the old
/// scans used (`date >= start && date <= end`). Windows produced by
/// `NocturnalAggregator.windows(fromAsleepSegments:)` are pairwise disjoint,
/// so an indexed lookup returns the same window the old `first(where:)`
/// scan found.
nonisolated enum RecoveryDailyAggregator {
    /// Everything `daily(_:)` needs, pre-converted out of HealthKit types so
    /// the aggregator stays testable without a store. Values are in display
    /// units: HRV in ms, heart/respiratory rates in bpm, oxygen already
    /// scaled to percentage points (HealthKit's fractional percent × 100).
    struct SampleInputs: Sendable {
        var calendar: Calendar
        var hrv: [(start: Date, end: Date, value: Double, sourceBundleID: String)]
        var restingHR: [(start: Date, end: Date, value: Double, sourceBundleID: String)]
        var respiratory: [(start: Date, end: Date, value: Double, sourceBundleID: String)]
        var oxygen: [(start: Date, end: Date, value: Double, sourceBundleID: String)]
        var asleepSegments: [(start: Date, end: Date, sourceBundleID: String)]
        /// Every sleep-analysis sample (asleep stages, awake, in-bed); raw
        /// category values drive the deep/REM/awake breakdown.
        var allSleepSegments: [(start: Date, end: Date, rawValue: Int)]
        var windows: [NocturnalAggregator.SleepWindow]
        var nocturnalHR: [(date: Date, bpm: Int, sourceBundleID: String)]
    }

    static func daily(_ inputs: SampleInputs) -> [RecoveryEngine.DailyHealthMetric] {
        // Only cancellation short-circuits: a user with no sleep tracking has
        // empty windows yet still gets all-day HRV / RHR / sleep metrics.
        guard !Task.isCancelled else { return [] }
        let calendar = inputs.calendar
        // One index, shared by every membership decision — the replacement
        // for the repeated `windows.first(where:)` scans (each sample used to
        // pay O(windows), and the sleeping-HR source line paid
        // O(days × samples × windows)).
        let windowIndex = NocturnalAggregator.SleepWindowIndex(inputs.windows)

        /// The night a respiratory/SpO₂ sample belongs to: the sleep window
        /// containing its midpoint, else the calendar day it ended.
        func readinessDay(start: Date, end: Date) -> Date {
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            if let window = windowIndex.window(containing: midpoint) {
                return window.day
            }
            return calendar.startOfDay(for: end)
        }

        // Bucket by calendar day. Sleep is attributed to the day it ENDED
        // (last night's sleep belongs to today's readiness). All-day HRV /
        // RHR remain as fallbacks when the nocturnal window is empty.
        var hrvByDay: [Date: [Double]] = [:]
        var hrvSourcesByDay: [Date: [String]] = [:]
        var nocturnalHRVSourcesByDay: [Date: [String]] = [:]
        for sample in inputs.hrv {
            guard !Task.isCancelled else { return [] }
            let day = calendar.startOfDay(for: sample.end)
            hrvByDay[day, default: []].append(sample.value)
            hrvSourcesByDay[day, default: []].append(sample.sourceBundleID)
            if let window = windowIndex.window(containing: sample.start) {
                nocturnalHRVSourcesByDay[window.day, default: []].append(sample.sourceBundleID)
            }
        }
        var rhrByDay: [Date: [Double]] = [:]
        var rhrSourcesByDay: [Date: [String]] = [:]
        for sample in inputs.restingHR {
            guard !Task.isCancelled else { return [] }
            let day = calendar.startOfDay(for: sample.end)
            rhrByDay[day, default: []].append(sample.value)
            rhrSourcesByDay[day, default: []].append(sample.sourceBundleID)
        }
        var respiratoryByDay: [Date: [Double]] = [:]
        var respiratorySourcesByDay: [Date: [String]] = [:]
        for sample in inputs.respiratory {
            guard !Task.isCancelled else { return [] }
            let day = readinessDay(start: sample.start, end: sample.end)
            respiratoryByDay[day, default: []].append(sample.value)
            respiratorySourcesByDay[day, default: []].append(sample.sourceBundleID)
        }
        var oxygenByDay: [Date: [Double]] = [:]
        var oxygenSourcesByDay: [Date: [String]] = [:]
        for sample in inputs.oxygen {
            guard !Task.isCancelled else { return [] }
            let day = readinessDay(start: sample.start, end: sample.end)
            oxygenByDay[day, default: []].append(sample.value)
            oxygenSourcesByDay[day, default: []].append(sample.sourceBundleID)
        }
        var sleepByDay: [Date: Int] = [:]
        var sleepSourcesByDay: [Date: [String]] = [:]
        for sample in inputs.asleepSegments {
            guard !Task.isCancelled else { return [] }
            let day = calendar.startOfDay(for: sample.end)
            sleepByDay[day, default: 0] += Int(sample.end.timeIntervalSince(sample.start) / 60)
            sleepSourcesByDay[day, default: []].append(sample.sourceBundleID)
        }
        // Stage breakdown (deep / REM / awake-in-bed). Sources that write
        // unstaged "asleep" samples leave these empty and the metric's stage
        // fields stay nil — total minutes drive the score either way.
        // Raw category values mirror HealthKit's sleep-analysis enum
        // (asleepDeep = 4, asleepREM = 5, awake = 2) without importing it.
        var deepByDay: [Date: Int] = [:]
        var remByDay: [Date: Int] = [:]
        var awakeByDay: [Date: Int] = [:]
        for sample in inputs.allSleepSegments {
            guard !Task.isCancelled else { return [] }
            let day = calendar.startOfDay(for: sample.end)
            let minutes = Int(sample.end.timeIntervalSince(sample.start) / 60)
            switch sample.rawValue {
            case 4: deepByDay[day, default: 0] += minutes
            case 5: remByDay[day, default: 0] += minutes
            case 2: awakeByDay[day, default: 0] += minutes
            default: break
            }
        }

        // Nocturnal summaries (HRV / HR bin medians) and the sleeping-HR
        // source attribution — both indexed, both single-pass.
        let sleepingHRSourcesByDay = NocturnalAggregator.sourcesByDay(
            windows: inputs.windows,
            hr: inputs.nocturnalHR.map { ($0.date, $0.sourceBundleID) }
        )
        let nightly = NocturnalAggregator.nightly(
            windows: inputs.windows,
            hrv: inputs.hrv.map { ($0.start, $0.value) },
            hr: inputs.nocturnalHR.map { ($0.date, $0.bpm) }
        )
        guard !Task.isCancelled else { return [] }

        // Merged sleep-window bounds per readiness day (min start, max end
        // over the night's windows) — the bed/wake anchors integrity
        // detection reads.
        var windowBoundsByDay: [Date: (start: Date, end: Date)] = [:]
        for window in inputs.windows {
            if let existing = windowBoundsByDay[window.day] {
                windowBoundsByDay[window.day] = (min(existing.start, window.start), max(existing.end, window.end))
            } else {
                windowBoundsByDay[window.day] = (window.start, window.end)
            }
        }

        let allDays = Set(hrvByDay.keys)
            .union(rhrByDay.keys)
            .union(respiratoryByDay.keys)
            .union(oxygenByDay.keys)
            .union(sleepByDay.keys)
            .union(nightly.keys)
        return allDays.sorted().map { day in
            RecoveryEngine.DailyHealthMetric(
                date: day,
                hrvSDNN: hrvByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                restingHR: rhrByDay[day].map { Int(($0.reduce(0, +) / Double($0.count)).rounded()) },
                respiratoryRate: respiratoryByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                oxygenSaturationPercent: oxygenByDay[day].map { $0.reduce(0, +) / Double($0.count) },
                sleepTotalMinutes: sleepByDay[day],
                source: "healthkit",
                hrvSourceBundleID: dominantSource(nocturnalHRVSourcesByDay[day] ?? hrvSourcesByDay[day] ?? []),
                restingHRSourceBundleID: dominantSource(rhrSourcesByDay[day] ?? []),
                sleepingHRSourceBundleID: dominantSource(sleepingHRSourcesByDay[day] ?? []),
                sleepSourceBundleID: dominantSource(sleepSourcesByDay[day] ?? []),
                respiratoryRateSourceBundleID: dominantSource(respiratorySourcesByDay[day] ?? []),
                oxygenSaturationSourceBundleID: dominantSource(oxygenSourcesByDay[day] ?? []),
                hrvSampleCount: hrvByDay[day]?.count,
                nocturnalHRV: nightly[day]?.hrv,
                nocturnalHRVOccupiedBinCount: nightly[day]?.hrvOccupiedBinCount,
                nocturnalHRVSampleSpanMinutes: nightly[day]?.hrvSampleSpanMinutes,
                sleepingHR: nightly[day]?.sleepingHR,
                sleepingHRSampleCount: nightly[day]?.sleepingHRSampleCount,
                sleepingHROccupiedBinCount: nightly[day]?.sleepingHROccupiedBinCount,
                sleepingHRSampleSpanMinutes: nightly[day]?.sleepingHRSampleSpanMinutes,
                sleepStart: windowBoundsByDay[day]?.start,
                sleepEnd: windowBoundsByDay[day]?.end,
                sleepDeepMinutes: deepByDay[day],
                sleepREMMinutes: remByDay[day],
                sleepAwakeMinutes: awakeByDay[day]
            )
        }
    }

    static func dominantSource(_ sources: [String]) -> String? {
        Dictionary(grouping: sources, by: { $0 })
            .max { lhs, rhs in lhs.value.count < rhs.value.count }?.key
    }
}