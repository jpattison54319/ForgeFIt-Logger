import Foundation

/// Banister/Coggan impulse-response model — the engine behind the Fitness-vs-Fatigue chart.
///
/// CTL ("fitness") and ATL ("fatigue") are exponentially-weighted moving averages of daily
/// training load with different time constants (42 and 7 days by convention — the values
/// popularized by Coggan/TrainingPeaks because they empirically track adaptation vs. acute
/// stress). TSB ("form") is their difference: a fresh training spike raises ATL faster than
/// CTL, so TSB goes negative (tired); a taper lets ATL decay first, so TSB turns positive
/// (peaked). The model only means anything if rest days are counted — a week off must decay
/// both curves — so the series walks every calendar day, treating missing days as zero load.
public enum FitnessFatigue {

    /// One day on the chart. `tsb` is derived rather than stored so the invariant
    /// tsb == ctl - atl can never drift.
    public struct Point: Equatable, Sendable {
        public let date: Date
        /// Chronic Training Load — long-time-constant EWMA, the "fitness" curve.
        public let ctl: Double
        /// Acute Training Load — short-time-constant EWMA, the "fatigue" curve.
        public let atl: Double
        /// Training Stress Balance ("form"): negative when fatigue outpaces fitness.
        public var tsb: Double { ctl - atl }

        public init(date: Date, ctl: Double, atl: Double) {
            self.date = date
            self.ctl = ctl
            self.atl = atl
        }
    }

    /// Builds the full CTL/ATL series from raw workout loads.
    ///
    /// Loads are bucketed by calendar start-of-day (two sessions in one day are one training
    /// impulse, so they sum), then EVERY day from the first to the last load is walked with
    /// the recursion `v = v + (load - v) / τ`. Days with no workout contribute load 0 —
    /// skipping them would freeze fatigue and make rest look free. Both curves start at 0,
    /// the standard CTL/ATL assumption that an athlete with no logged history is untrained;
    /// early values are therefore biased low until ~1 time constant of history exists.
    ///
    /// Time constants are clamped to ≥ 1 day because the discrete recursion overshoots and
    /// oscillates for τ < 1, which can never represent a physical fitness response.
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
        var ctl = 0.0
        var atl = 0.0
        var day = firstDay
        while day <= lastDay {
            let load = buckets[day] ?? 0
            ctl += (load - ctl) / ctlTau
            atl += (load - atl) / atlTau
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
    /// Exists so the "current form" readout stays honest when the athlete hasn't trained
    /// recently: the last *logged* point would show week-old fatigue, but a week off has
    /// really decayed both curves. Implemented by injecting a zero-load impulse at `now` —
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
