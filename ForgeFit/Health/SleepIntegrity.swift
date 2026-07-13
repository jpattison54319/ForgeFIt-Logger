import Foundation

/// A flagged night surfaced to the user for correction: the readiness day and
/// the fragment of sleep that was actually captured.
struct SleepIntegrityAlert: Equatable {
    let day: Date
    let capturedMinutes: Int
}

/// Detects nights whose sleep data is a partial-wear fragment rather than a
/// real short night, so a data-collection gap is never reported as a measured
/// recovery deficit.
///
/// The hard problem: a genuinely bad night (real 3 h of sleep) and a
/// partial-wear night (watch put on at 5 a.m.) both show a low duration, so
/// duration alone can't separate them. What separates them is *coverage* and
/// *timing*: a real short night still logs dense heart-rate/HRV samples across
/// a window anchored near the user's habitual bed/wake times; a partial-wear
/// night shows a sparse fragment whose window starts hours late or ends hours
/// early. We flag a night low-integrity only when its duration is well below
/// the user's own baseline AND (its samples are sparse OR its window is
/// anchored far from habitual) — real insomnia keeps both anchors and coverage.
enum SleepIntegrity {
    /// Marker strings stamped into `DailyHealthMetric.integrityFlags`.
    enum Flag {
        /// Probable partial-wear capture — present but untrustworthy sleep.
        static let partialWear = "sleep-partial-wear"
        /// The user resolved the night by hand (confirm / edit / mark untracked).
        static let userCorrected = "sleep-user-corrected"
    }

    // MARK: - Thresholds

    /// Minimum prior nights with sleep before the baseline is trusted enough to
    /// judge an outlier. Below this we can't tell a short night from a habit.
    static let minBaselineNights = 10
    /// A night must fall at/below this percentile of the user's sleep history
    /// to even be a candidate — the low-duration precondition.
    static let outlierPercentile = 0.10
    /// …and at least this far below the user's median, so a user who sleeps a
    /// tight 7–7.5 h every night doesn't get a 6.5 h night flagged.
    static let minShortfallMinutes = 150
    /// Nocturnal HRV sample count at/below which coverage counts as sparse.
    static let sparseHRVSamples = 3
    /// Nocturnal HR sample count at/below which coverage counts as sparse.
    /// Apple Watch logs HR every few minutes asleep, so a real night clears
    /// this easily; a short fragment does not.
    static let sparseHRSamples = 6
    /// Bed/wake anchor deviation (minutes) beyond which the window is judged
    /// mis-anchored — the "put the watch on late / took it off early" tell.
    static let anchorDeviationMinutes = 90
    /// Coverage floor (minutes) and HRV-sample floor below which a nocturnal
    /// HR/HRV reading is a circadian-biased fragment, not a usable mean. Fable
    /// 5's rule: a sub-hour window near dawn reads a flatteringly low HR / high
    /// HRV, so drop it and fall back to the all-day baseline.
    static let minTrustworthyWindowMinutes = 60
    static let minTrustworthyHRVSamples = 10

    // MARK: - Detection

    /// Returns `metrics` with `integrityFlags` stamped on any night whose sleep
    /// is probable partial-wear. Pure: the baseline is drawn from the other
    /// nights in the same series, and already-flagged partial nights are
    /// excluded from that baseline so a run of bad-wear nights can't drag the
    /// reference down and hide the next one.
    static func annotate(_ metrics: [RecoveryEngine.DailyHealthMetric]) -> [RecoveryEngine.DailyHealthMetric] {
        let calendar = Calendar.current
        let sorted = metrics.sorted { $0.date < $1.date }
        var result = sorted
        for index in result.indices {
            // Baseline = every OTHER night with sleep. Nights already carrying a
            // user correction stay in the baseline via their corrected value;
            // auto-flagged partial nights are dropped so they can't recalibrate
            // "normal" downward (the contamination gotcha).
            let others = result.enumerated()
                .filter { $0.offset != index && !$0.element.sleepLikelyPartial }
                .map(\.element)
            if isPartialWear(result[index], baseline: others, calendar: calendar) {
                result[index].integrityFlags.insert(Flag.partialWear)
            }
        }
        return result
    }

    /// Whether a single night looks like partial-wear capture given the user's
    /// other nights. A user-corrected night is never re-flagged.
    static func isPartialWear(
        _ metric: RecoveryEngine.DailyHealthMetric,
        baseline: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> Bool {
        guard !metric.sleepUserCorrected else { return false }
        guard let sleep = metric.sleepTotalMinutes else { return false }

        let durations = baseline.compactMap(\.sleepTotalMinutes).sorted()
        guard durations.count >= minBaselineNights else { return false }

        // Precondition: a genuine outlier in duration for THIS user.
        let median = percentile(durations, 0.5)
        let lowCutoff = percentile(durations, outlierPercentile)
        guard sleep <= lowCutoff, median - sleep >= minShortfallMinutes else { return false }

        // Discriminator 1 — sparse coverage. A real short night still logs
        // dense samples; a fragment doesn't.
        let hrvCount = metric.hrvSampleCount ?? 0
        let hrCount = metric.sleepingHRSampleCount ?? 0
        let sparseCoverage = hrvCount <= sparseHRVSamples && hrCount <= sparseHRSamples

        // Discriminator 2 — mis-anchored window. A real short night keeps
        // normal-ish bed/wake times; a partial-wear window starts hours late
        // or ends hours early relative to the user's habit.
        let misAnchored = windowMisAnchored(metric, baseline: baseline, calendar: calendar)

        return sparseCoverage || misAnchored
    }

    /// True when the night's sleep window STARTS well after the user's habitual
    /// bedtime — the watch went on hours into the night, so the sleep before it
    /// is missing. This is the one unambiguous anchor tell.
    ///
    /// A late bedtime is unambiguous; an early wake is not. "Watch died at 2am
    /// after a full night" and "genuinely woke at 2am" produce an identical
    /// early-ending window with identical (dense) coverage — nothing in the
    /// data separates them — so waking early is deliberately NOT an auto-flag
    /// (that would suppress real short nights, the failure mode we're guarding
    /// against). Those the user corrects by hand instead.
    static func windowMisAnchored(
        _ metric: RecoveryEngine.DailyHealthMetric,
        baseline: [RecoveryEngine.DailyHealthMetric],
        calendar: Calendar = .current
    ) -> Bool {
        guard let start = metric.sleepStart else { return false }
        let starts = baseline.compactMap { $0.sleepStart.map { minuteOfDay($0, calendar: calendar) } }
        guard starts.count >= minBaselineNights else { return false }

        let habitualBed = circularMedianMinute(starts)
        // Signed lateness on the 24 h clock: positive = later to bed than habit.
        let lateness = signedForwardMinutes(from: habitualBed, to: minuteOfDay(start, calendar: calendar))
        return lateness > anchorDeviationMinutes
    }

    /// Whether a nocturnal HR/HRV reading from this night is dense enough and
    /// long enough to be a trustworthy mean rather than a circadian-biased
    /// fragment. Used to gate the nocturnal-over-all-day preference.
    static func nocturnalReadingTrustworthy(_ metric: RecoveryEngine.DailyHealthMetric) -> Bool {
        guard let start = metric.sleepStart, let end = metric.sleepEnd else {
            // No bounds: fall back to sample count alone.
            return (metric.hrvSampleCount ?? 0) >= minTrustworthyHRVSamples
        }
        let windowMinutes = end.timeIntervalSince(start) / 60
        return windowMinutes >= Double(minTrustworthyWindowMinutes)
            && (metric.hrvSampleCount ?? 0) >= minTrustworthyHRVSamples
    }

    // MARK: - Statistics helpers

    /// Linear-interpolated percentile of a pre-sorted ascending array.
    static func percentile(_ sorted: [Int], _ p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = Double(sorted.count - 1) * min(1, max(0, p))
        let lower = Int(rank.rounded(.down))
        let upper = Int(rank.rounded(.up))
        if lower == upper { return sorted[lower] }
        let fraction = rank - Double(lower)
        return Int((Double(sorted[lower]) * (1 - fraction) + Double(sorted[upper]) * fraction).rounded())
    }

    static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// Shortest distance between two minute-of-day values on a 24 h clock
    /// (so 23:30 and 00:30 are 60 min apart, not 1380).
    static func circularDistanceMinutes(_ a: Int, _ b: Int) -> Int {
        let raw = abs(a - b) % 1440
        return min(raw, 1440 - raw)
    }

    /// Signed minutes from `from` to `to` on a 24 h clock, folded to
    /// [-720, 720]: positive means `to` is *later* in the day than `from`
    /// (crossing at most 12 h forward), negative means earlier. Lets a "later
    /// to bed than usual" judgment ignore an "earlier to bed" one.
    static func signedForwardMinutes(from: Int, to: Int) -> Int {
        let forward = ((to - from) % 1440 + 1440) % 1440
        return forward > 720 ? forward - 1440 : forward
    }

    /// Median of minute-of-day values on a circular clock: rotate to the sample
    /// that minimizes total circular distance, take the plain median there,
    /// rotate back. Robust to the midnight wrap that breaks a linear median
    /// (bedtimes straddling 00:00).
    static func circularMedianMinute(_ minutes: [Int]) -> Int {
        guard !minutes.isEmpty else { return 0 }
        var best = minutes[0]
        var bestCost = Int.max
        for pivot in minutes {
            let cost = minutes.reduce(0) { $0 + circularDistanceMinutes($1, pivot) }
            if cost < bestCost { bestCost = cost; best = pivot }
        }
        return best
    }
}
