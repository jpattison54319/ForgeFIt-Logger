import Foundation

/// Startup-normalized load smoothing for the long-term load, short-term load,
/// and load-balance chart. The time constants are display settings, not
/// universal physiological fitness/fatigue constants.
public enum FitnessFatigue {

    /// One day on the chart. Legacy property names remain for source
    /// compatibility; the product labels them long-term load, short-term load,
    /// and load balance.
    public struct Point: Equatable, Sendable {
        public let date: Date
        /// Startup-normalized long-time-constant load EWMA.
        public let ctl: Double
        /// Startup-normalized short-time-constant load EWMA.
        public let atl: Double
        /// Load balance: long-term EWMA minus short-term EWMA.
        public var tsb: Double { ctl - atl }

        public init(date: Date, ctl: Double, atl: Double) {
            self.date = date
            self.ctl = ctl
            self.atl = atl
        }
    }

    /// Builds both startup-normalized EWMA series from raw workout loads.
    ///
    /// Loads are bucketed by calendar start-of-day (two sessions in one day are one training
    /// impulse, so they sum), then EVERY day from the first to the last load is walked with
    /// the recursion `v = v + (load - v) / τ`. Days with no workout contribute load 0 —
    /// skipping them would freeze the smoothing. Sum/weight normalization avoids
    /// inventing a low long-term value solely because history starts today.
    ///
    /// Time constants are clamped to ≥ 1 day because the discrete recursion overshoots and
    /// oscillates for τ < 1 and is not useful as a display smoother.
    public static func series(
        dailyLoads: [(date: Date, load: Double)],
        ctlDays: Double = 42,
        atlDays: Double = 7,
        calendar: Calendar = .current
    ) -> [Point] {
        guard !dailyLoads.isEmpty else { return [] }

        var buckets: [Date: Double] = [:]
        for entry in dailyLoads {
            buckets[calendar.startOfDay(for: entry.date), default: 0] += entry.load
        }
        guard let firstDay = buckets.keys.min(), let lastDay = buckets.keys.max() else {
            return []
        }

        let ctlTau = max(1, ctlDays)
        let atlTau = max(1, atlDays)

        var points: [Point] = []
        var ctlSum = 0.0
        var atlSum = 0.0
        var ctlWeight = 0.0
        var atlWeight = 0.0
        let ctlDecay = exp(-1 / ctlTau)
        let atlDecay = exp(-1 / atlTau)
        var day = firstDay
        while day <= lastDay {
            let load = buckets[day] ?? 0
            ctlSum = ctlDecay * ctlSum + load
            atlSum = atlDecay * atlSum + load
            ctlWeight = ctlDecay * ctlWeight + 1
            atlWeight = atlDecay * atlWeight + 1
            let ctl = ctlSum / ctlWeight
            let atl = atlSum / atlWeight
            points.append(Point(date: day, ctl: ctl, atl: atl))
            // Calendar day-stepping (not +86400s) so DST transitions don't skip or
            // double-count a bucket.
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return points
    }

    /// Latest point extended with zero-load days through `now`.
    ///
    /// Extends the descriptive load-balance readout through zero-load days. The
    /// last logged point would otherwise be stale. Implemented by injecting a
    /// zero-load impulse at `now` —
    /// same-day loads sum, so it is a no-op when `now` falls on an already-logged day and
    /// otherwise forces the day-walk to continue to today. Returns nil only when there is
    /// no history at all (a zero/zero point would render as fake data on the chart).
    public static func today(
        dailyLoads: [(date: Date, load: Double)],
        ctlDays: Double = 42,
        atlDays: Double = 7,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Point? {
        guard !dailyLoads.isEmpty else { return nil }
        var extended = dailyLoads
        extended.append((date: now, load: 0))
        return series(
            dailyLoads: extended,
            ctlDays: ctlDays,
            atlDays: atlDays,
            calendar: calendar
        ).last
    }
}
