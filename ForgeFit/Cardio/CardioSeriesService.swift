import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Builds and persists a session's downsampled HR + distance time-series at
/// completion, then optimistically applies after-the-fact interval detection to
/// free-form runs. The series feeds the critical-pace curve; the detected laps
/// are ordinary `CardioSplitModel`s flagged `autoDetected` so they can be
/// reverted or edited — manual interval plans and zone-lock are untouched.
@MainActor
enum CardioSeriesService {

    /// Assemble the series, store it, and (for free-form sessions) auto-detect
    /// and apply interval laps. Safe to call once per completed session.
    static func finalize(session: CardioSessionModel, hadManualIntervalPlan: Bool, in context: ModelContext) async {
        let start = session.liveStartedAt ?? session.startedAt
        let end = session.endedAt ?? Date()
        guard end > start else { return }

        // Capture BLE monitor readings up front — the hub's buffer is
        // session-scoped and may be dropped before this async work resumes.
        let bleSamples = LiveMetricsHub.shared.bleSamples(from: start, to: end)
        let series = await buildSeries(start: start, end: end, routePoints: session.routePoints, extraHRSamples: bleSamples)
        guard !series.isEmpty else { return }
        session.sampleSeriesJSON = series.encodedJSON()
        // Real time-in-zone from the series replaces the avg-HR estimate that
        // completion stamped as a provisional value — this is what lets the
        // zone bar honestly say "Measured". Sparse HR keeps the estimate.
        if let measured = CardioMetrics.measuredZoneSecondsArray(series: series) {
            session.hrZoneSeconds = measured
        }
        session.updatedAt = Date()

        // A yoga class's HR ebb and flow is not interval training — the series
        // is kept (zones, HR chart) but never chopped into work/recover laps.
        if !hadManualIntervalPlan, !session.isYogaSession, !session.intervalsAutoApplied,
           let segments = CardioSampleSeries.detectIntervals(in: series),
           segments.contains(where: { $0.kind == .work }) {
            applyDetectedIntervals(segments, to: session, series: series, start: start, in: context)
        }
        try? context.save()
    }

    // MARK: - Series assembly

    static func buildSeries(
        start: Date,
        end: Date,
        routePoints: [CardioRoutePointModel],
        extraHRSamples: [LiveHRAggregator.HRSample] = []
    ) async -> CardioSampleSeries {
        let duration = max(0, Int(end.timeIntervalSince(start)))
        guard duration > 0 else { return CardioSampleSeries() }

        // HealthKit samples plus live BLE-monitor readings (not in HealthKit
        // yet mid-workout); overlaps blend out in the bucket averages.
        let hkSamples = await HealthService.shared.heartRateSamples(from: start, to: end)
        let hr = (hkSamples + extraHRSamples.map { (date: $0.date, bpm: $0.bpm) })
            .map { (t: Int($0.date.timeIntervalSince(start)), bpm: $0.bpm) }
            .filter { $0.t >= 0 && $0.t <= duration }

        // Cumulative distance from the GPS route (nil for treadmill/no-GPS).
        let sorted = routePoints.sorted { $0.timestamp < $1.timestamp }
        var cumulative: [(t: Int, m: Double)] = []
        if sorted.count >= 2 {
            var accumulated = 0.0
            cumulative.append((max(0, Int(sorted[0].timestamp.timeIntervalSince(start))), 0))
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                accumulated += CardioRouteMath.distanceMeters(a, b)
                cumulative.append((max(0, Int(b.timestamp.timeIntervalSince(start))), accumulated))
            }
        }

        return CardioSampleSeries(samples: assemble(hr: hr, cumulative: cumulative, duration: duration))
    }

    /// Pure single-pass bucketing. The old per-bucket `filter` was
    /// O(buckets × samples) on the main actor — a 3 h run (~1 sample/5 s)
    /// meant ~2.3 M comparisons at finish. Sorting once and sweeping two
    /// monotonic cursors (HR window + route segment) makes it
    /// O(n log n + buckets).
    nonisolated static func assemble(
        hr: [(t: Int, bpm: Int)],
        cumulative: [(t: Int, m: Double)],
        duration: Int,
        step: Int = 10
    ) -> [CardioSampleSeries.Sample] {
        let sortedHR = hr.sorted { $0.t < $1.t }
        var samples: [CardioSampleSeries.Sample] = []
        var lower = 0          // first HR sample with t >= current bucket start
        var routeIndex = 0     // route segment cursor (buckets ascend in t)
        for t in stride(from: 0, through: duration, by: step) {
            let bucketStart = t - step / 2
            let bucketEnd = t + step / 2   // exclusive, matching the old filter
            while lower < sortedHR.count, sortedHR[lower].t < bucketStart { lower += 1 }
            var upper = lower
            var sum = 0
            while upper < sortedHR.count, sortedHR[upper].t < bucketEnd {
                sum += sortedHR[upper].bpm
                upper += 1
            }
            let count = upper - lower
            let bpm = count == 0 ? nil : Int((Double(sum) / Double(count)).rounded())
            let meters = interpolate(cumulative, at: t, movingForwardFrom: &routeIndex)
            if bpm != nil || meters != nil {
                samples.append(.init(t: t, hr: bpm, meters: meters))
            }
        }
        return samples
    }

    /// Linear interpolation with a forward-only segment cursor — callers
    /// query ascending `t`, so the scan never restarts from the front.
    private nonisolated static func interpolate(
        _ points: [(t: Int, m: Double)],
        at t: Int,
        movingForwardFrom index: inout Int
    ) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if t <= first.t { return first.m }
        if t >= last.t { return last.m }
        while index + 1 < points.count, points[index + 1].t < t { index += 1 }
        let a = points[index]
        let b = points[index + 1]
        guard b.t > a.t else { return a.m }
        return a.m + (b.m - a.m) * (Double(t - a.t) / Double(b.t - a.t))
    }

    // MARK: - Applying / reverting detected intervals

    static func applyDetectedIntervals(
        _ segments: [CardioSampleSeries.DetectedSegment],
        to session: CardioSessionModel,
        series: CardioSampleSeries,
        start: Date,
        in context: ModelContext
    ) {
        // Replace any existing (distance) splits so the detected laps are the view.
        for split in session.splits { context.delete(split) }
        session.splits = []

        var workNumber = 0
        for (index, segment) in segments.enumerated() {
            if segment.kind == .work { workNumber += 1 }
            let label: String = {
                switch segment.kind {
                case .work: return "Work \(workNumber)"
                case .recover:
                    if workNumber == 0 { return "Warm-up" }
                    if index == segments.count - 1 { return "Cool-down" }
                    return "Recover \(workNumber)"
                }
            }()
            let meters = (series.cumulativeMeters(at: segment.endT) ?? 0) - (series.cumulativeMeters(at: segment.startT) ?? 0)
            let duration = max(1, segment.durationSeconds)
            let pace = meters > 0 ? Double(duration) / (meters / 1000) : 0
            let split = CardioSplitModel(
                userID: session.userID,
                cardioSessionID: session.id,
                index: index,
                distanceMeters: max(0, meters),
                durationSeconds: duration,
                paceSecondsPerKm: pace,
                label: label,
                autoDetected: true,
                startedAt: start.addingTimeInterval(TimeInterval(segment.startT)),
                endedAt: start.addingTimeInterval(TimeInterval(segment.endT))
            )
            context.insert(split)
            session.splits.append(split)
        }
        session.intervalsAutoApplied = true
        session.updatedAt = Date()
    }

    /// Remove the auto-detected laps and restore the default distance splits.
    static func revertAutoIntervals(for session: CardioSessionModel, in context: ModelContext) {
        for split in session.splits where split.autoDetected { context.delete(split) }
        session.splits = session.splits.filter { !$0.autoDetected }
        session.intervalsAutoApplied = false
        session.updatedAt = Date()
        // Rebuild the plain distance splits for GPS runs.
        if session.routePoints.count >= 2 {
            CardioRouteMath.replaceSplits(for: session, in: context)
        }
        try? context.save()
    }
}
