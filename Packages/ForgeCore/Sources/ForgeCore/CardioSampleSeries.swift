import Foundation

/// A downsampled per-session time-series of heart rate + cumulative distance,
/// captured once when a cardio session finishes and persisted as JSON on the
/// session. It's the shared substrate for cardio-native analytics that a single
/// average can't express: the critical-pace curve (best sustained pace at N
/// minutes) and after-the-fact interval detection. Kept in ForgeCore, pure and
/// testable, so the math lives in one place.
public struct CardioSampleSeries: Codable, Equatable, Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        /// Seconds from the session's live start.
        public var t: Int
        /// Heart rate (bpm) at/around `t`, if a sample was available.
        public var hr: Int?
        /// Cumulative distance (meters) at `t`, if distance is being tracked.
        public var meters: Double?

        public init(t: Int, hr: Int? = nil, meters: Double? = nil) {
            self.t = t
            self.hr = hr
            self.meters = meters
        }
    }

    public var samples: [Sample]

    public init(samples: [Sample] = []) {
        self.samples = samples.sorted { $0.t < $1.t }
    }

    public var isEmpty: Bool { samples.isEmpty }
    public var durationSeconds: Int { samples.last.map { max(0, $0.t) } ?? 0 }
    public var hasDistance: Bool { samples.contains { $0.meters != nil } }
    public var hasHeartRate: Bool { samples.contains { $0.hr != nil } }

    // MARK: - JSON persistence

    public func encodedJSON() -> String? {
        guard !samples.isEmpty, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> CardioSampleSeries? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CardioSampleSeries.self, from: data)
    }

    /// Cumulative distance (meters) at an arbitrary offset, linearly
    /// interpolated between samples. nil when the session has no distance series.
    public func cumulativeMeters(at t: Int) -> Double? {
        let pts = samples.compactMap { s in s.meters.map { (t: s.t, m: $0) } }
        guard let first = pts.first, let last = pts.last else { return nil }
        if t <= first.t { return first.m }
        if t >= last.t { return last.m }
        for (a, b) in zip(pts, pts.dropFirst()) where t >= a.t && t <= b.t {
            guard b.t > a.t else { return a.m }
            return a.m + (b.m - a.m) * (Double(t - a.t) / Double(b.t - a.t))
        }
        return last.m
    }

    // MARK: - Critical pace

    /// The fastest pace (seconds per km) sustained for at least `windowSeconds`
    /// anywhere in the session — one point on the mean-maximal-pace curve.
    /// Returns nil when there isn't a distance series long enough for the window.
    public func bestPaceSecPerKm(windowSeconds: Int) -> Double? {
        let pts = samples.compactMap { s in s.meters.map { (t: s.t, m: $0) } }
        guard pts.count >= 2, let span = pts.last.map({ $0.t - pts[0].t }), span >= windowSeconds else { return nil }

        var best: Double?
        var j = 0
        for i in 0..<pts.count {
            if j < i { j = i }
            // Advance j to the first sample at least `windowSeconds` after i.
            while j < pts.count && pts[j].t - pts[i].t < windowSeconds { j += 1 }
            guard j < pts.count else { break }
            let dt = pts[j].t - pts[i].t
            let dm = pts[j].m - pts[i].m
            guard dt > 0, dm > 0 else { continue }
            let pace = Double(dt) / (dm / 1000)   // sec per km
            if best == nil || pace < best! { best = pace }
        }
        return best
    }

    /// Best pace at each of the requested window lengths (seconds), skipping
    /// windows longer than the session.
    public func criticalPaceCurve(windows: [Int]) -> [(windowSeconds: Int, paceSecPerKm: Double)] {
        windows.compactMap { w in bestPaceSecPerKm(windowSeconds: w).map { (w, $0) } }
    }

    // MARK: - Time in zones

    /// Measured seconds per heart-rate zone (index 0 = Z1) summed from the HR
    /// samples, each bucket contributing `step` seconds to the zone returned by
    /// `classify` (clamped to 1...zoneCount). Returns nil when the series has
    /// too little heart-rate coverage to be honest — fewer than `minSamples` HR
    /// points, or HR present for under `minCoverage` of the session span — so
    /// callers fall back to an estimate and label it as such.
    public func hrZoneSeconds(
        zoneCount: Int = 5,
        step: Int = 10,
        minSamples: Int = 6,
        minCoverage: Double = 0.5,
        classify: (Int) -> Int
    ) -> [Int]? {
        let hrValues = samples.compactMap(\.hr)
        guard hrValues.count >= minSamples, zoneCount > 0, step > 0 else { return nil }
        // Buckets stride 0...duration inclusive, so the span is duration + step.
        let span = Double(durationSeconds + step)
        guard span > 0, Double(hrValues.count * step) / span >= minCoverage else { return nil }
        var zones = [Int](repeating: 0, count: zoneCount)
        for bpm in hrValues {
            let zone = min(max(classify(bpm), 1), zoneCount)
            zones[zone - 1] += step
        }
        return zones
    }

    // MARK: - Interval detection

    public struct DetectedSegment: Equatable, Sendable {
        public enum Kind: String, Sendable { case work, recover }
        public var kind: Kind
        public var startT: Int
        public var endT: Int
        public init(kind: Kind, startT: Int, endT: Int) {
            self.kind = kind
            self.startT = startT
            self.endT = endT
        }
        public var durationSeconds: Int { max(0, endT - startT) }
    }

    /// Heuristic after-the-fact interval detection from the heart-rate series
    /// (works for treadmill and GPS alike). Returns alternating work/recover
    /// segments only when the effort clearly looks like intervals — at least
    /// `minWorkBouts` sustained surges over a threshold; otherwise nil (a steady
    /// run shouldn't be chopped into fake laps).
    public static func detectIntervals(
        in series: CardioSampleSeries,
        minWorkSeconds: Int = 20,
        minRecoverSeconds: Int = 15,
        minWorkBouts: Int = 3,
        minSpreadBPM: Int = 15
    ) -> [DetectedSegment]? {
        let hrPts = series.samples.compactMap { s in s.hr.map { (t: s.t, hr: $0) } }
        guard hrPts.count >= 6, let totalSpan = hrPts.last.map({ $0.t - hrPts[0].t }), totalSpan >= 180 else { return nil }

        let sortedHR = hrPts.map(\.hr).sorted()
        let baseline = median(sortedHR)
        guard let peak = sortedHR.last, Double(peak) - baseline >= Double(minSpreadBPM) else { return nil }
        // Midpoint between the aerobic baseline and the peak effort.
        let threshold = baseline + (Double(peak) - baseline) * 0.5

        // Classify each point, then collapse into contiguous high/low runs.
        struct Run { var high: Bool; var startT: Int; var endT: Int }
        var runs: [Run] = []
        for point in hrPts {
            let high = Double(point.hr) >= threshold
            if var last = runs.last, last.high == high {
                last.endT = point.t
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(high: high, startT: point.t, endT: point.t))
            }
        }

        // A work bout = a high run lasting at least minWorkSeconds; drop noise.
        let workBouts = runs.filter { $0.high && ($0.endT - $0.startT) >= minWorkSeconds }
        guard workBouts.count >= minWorkBouts else { return nil }

        // Emit alternating segments spanning the whole session; short high blips
        // (< minWorkSeconds) fold into the surrounding recover.
        var segments: [DetectedSegment] = []
        let start = hrPts[0].t
        let end = hrPts.last!.t
        var cursor = start
        for bout in workBouts {
            let workStart = max(cursor, bout.startT)
            if workStart > cursor {
                segments.append(DetectedSegment(kind: .recover, startT: cursor, endT: workStart))
            }
            let workEnd = min(end, bout.endT)
            segments.append(DetectedSegment(kind: .work, startT: workStart, endT: workEnd))
            cursor = workEnd
        }
        if cursor < end {
            segments.append(DetectedSegment(kind: .recover, startT: cursor, endT: end))
        }
        return segments.filter { $0.durationSeconds > 0 }
    }

    private static func median(_ sorted: [Int]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? Double(sorted[mid - 1] + sorted[mid]) / 2 : Double(sorted[mid])
    }
}
