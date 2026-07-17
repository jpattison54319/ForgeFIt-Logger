import Foundation

/// Best-effort split times ("fastest 1 km / 1 mi / 5 km anywhere in the
/// session") computed from a cumulative-distance series. Lives in ForgeCore so
/// the sliding-window math is pure and testable, and because the naive
/// per-target scan is O(n²) — a watch session can carry hundreds of samples and
/// we compute six targets per session on the history screen, so each target
/// must stay O(n) via a two-pointer sweep.
///
/// Windows are refined with linear interpolation at the edges: the recorded
/// samples rarely land exactly on the target distance, and snapping to whole
/// samples would overstate a 1 km effort by up to a full sampling interval
/// (10+ s), which is far more than the pace differences users care about.
public enum DistanceBestEfforts {

    /// One point on the session's best-effort table.
    public struct Effort: Equatable, Sendable {
        /// The distance this effort covers (e.g. 1000 for "1 km").
        public var targetMeters: Double
        /// Minimum time (seconds, interpolated) to cover `targetMeters`
        /// anywhere in the session.
        public var seconds: Double
        /// Display label for the target ("1 km", "1 mi", "5 km", ...).
        public var label: String

        public init(targetMeters: Double, seconds: Double, label: String) {
            self.targetMeters = targetMeters
            self.seconds = seconds
            self.label = label
        }
    }

    /// The race-adjacent distances runners actually compare against
    /// (400 m track lap through half marathon). 1 mi is the exact
    /// international mile (1609.344 m) so a treadmill mile and a GPS mile
    /// agree; half marathon is 21.0975 km per World Athletics.
    public static let standardTargets: [(meters: Double, label: String)] = [
        (400, "400 m"),
        (1000, "1 km"),
        (1609.344, "1 mi"),
        (5000, "5 km"),
        (10000, "10 km"),
        (21097.5, "Half marathon"),
    ]

    /// Fastest time to cover each target distance anywhere in the session.
    ///
    /// `samples` carry CUMULATIVE meters at each `t`. Decreases in the
    /// cumulative series (GPS jitter reporting the runner "moving backwards")
    /// are clamped flat rather than trusted: a best-effort window that banks
    /// negative distance could otherwise report an impossible (even negative)
    /// time. Targets longer than the distance actually covered are skipped —
    /// an extrapolated "half marathon effort" from a 5 km jog would be
    /// fiction. Fewer than two samples yields no windows at all.
    public static func bestEfforts(
        samples: [(t: Int, meters: Double)],
        targets: [(meters: Double, label: String)] = standardTargets
    ) -> [Effort] {
        guard samples.count >= 2 else { return [] }

        // Sort by time and clamp to a monotone cumulative series.
        let sorted = samples.sorted { $0.t < $1.t }
        var pts: [(t: Double, m: Double)] = []
        pts.reserveCapacity(sorted.count)
        var runningMax = -Double.infinity
        for s in sorted {
            runningMax = Swift.max(runningMax, s.meters)
            pts.append((Double(s.t), runningMax))
        }

        guard let first = pts.first, let last = pts.last else { return [] }
        let covered = last.m - first.m
        guard covered > 0 else { return [] }

        var efforts: [Effort] = []
        for target in targets where target.meters > 0 && target.meters <= covered {
            if let seconds = minSeconds(toCover: target.meters, over: pts) {
                efforts.append(Effort(targetMeters: target.meters, seconds: seconds, label: target.label))
            }
        }
        return efforts
    }

    /// Convenience over a persisted series: samples without distance (HR-only
    /// buckets) carry no window information, so they're dropped before the
    /// sweep rather than treated as zero-progress points.
    public static func fromSeries(_ series: CardioSampleSeries) -> [Effort] {
        bestEfforts(samples: series.samples.compactMap { s in
            s.meters.map { (t: s.t, meters: $0) }
        })
    }

    // MARK: - Sliding window

    /// Minimum window duration covering `target` meters over a monotone
    /// cumulative series. Because the cumulative curve is piecewise linear,
    /// the optimal window always has one edge on a sample point (duration is
    /// linear in the start time while both edges stay inside their segments,
    /// so the minimum sits at a segment boundary). Two O(n) two-pointer
    /// sweeps therefore cover every candidate: start anchored on a sample
    /// with the end interpolated, and end anchored with the start
    /// interpolated.
    private static func minSeconds(toCover target: Double, over pts: [(t: Double, m: Double)]) -> Double? {
        var best: Double?

        // Forward sweep: start at sample i, interpolate the crossing end.
        var j = 0
        for i in 0..<pts.count {
            while j < pts.count, pts[j].m - pts[i].m < target { j += 1 }
            guard j < pts.count else { break }
            // Loop invariants give pts[j-1].m < needed <= pts[j].m, so the
            // segment has positive rise and the interpolation is well-defined.
            let needed = pts[i].m + target
            let a = pts[j - 1], b = pts[j]
            let endT = a.t + (b.t - a.t) * (needed - a.m) / (b.m - a.m)
            let duration = endT - pts[i].t
            if best == nil || duration < best! { best = duration }
        }

        // Backward sweep: end at sample j, interpolate the latest start.
        var i = pts.count - 1
        for jEnd in stride(from: pts.count - 1, through: 0, by: -1) {
            if i > jEnd { i = jEnd }
            while i >= 0, pts[jEnd].m - pts[i].m < target { i -= 1 }
            guard i >= 0 else { break }
            // pts[i].m <= needed < pts[i+1].m, so again a positive rise.
            let needed = pts[jEnd].m - target
            let a = pts[i], b = pts[i + 1]
            let startT = a.t + (b.t - a.t) * (needed - a.m) / (b.m - a.m)
            let duration = pts[jEnd].t - startT
            if best == nil || duration < best! { best = duration }
        }

        // Non-decreasing time and a positive target guarantee non-negative
        // durations; clamp defensively so float noise can't leak a -0.0.
        return best.map { Swift.max(0, $0) }
    }
}
