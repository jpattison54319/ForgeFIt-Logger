import Foundation
import Testing
@testable import ForgeFit

/// Verifies the two-score recovery model: the acute daily score reacts to one
/// bad night, the chronic trend doesn't; load balance can cap but not inflate;
/// sleep need personalizes upward only; and the guidance text always agrees
/// with the flags that shaped the number.
struct DailyReadinessTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `days` of stable history (HRV 80 ms nocturnal, sleeping HR 55, 8 h sleep),
    /// with today overridable.
    private func metrics(
        days: Int = 40,
        todayHRV: Double? = 80,
        todaySleepingHR: Int? = 55,
        todaySleepMinutes: Int? = 480,
        historySleepMinutes: Int = 480
    ) -> [RecoveryEngine.DailyHealthMetric] {
        var out: [RecoveryEngine.DailyHealthMetric] = []
        for day in 1...days {
            let date = cal.date(byAdding: .day, value: -day, to: now)!
            out.append(RecoveryEngine.DailyHealthMetric(
                date: date, hrvSDNN: nil, hrvRMSSD: nil, restingHR: nil,
                sleepTotalMinutes: historySleepMinutes, source: "test", hrvSampleCount: 5,
                nocturnalHRV: 80, sleepingHR: 55
            ))
        }
        out.append(RecoveryEngine.DailyHealthMetric(
            date: now, hrvSDNN: nil, hrvRMSSD: nil, restingHR: nil,
            sleepTotalMinutes: todaySleepMinutes, source: "test", hrvSampleCount: 5,
            nocturnalHRV: todayHRV, sleepingHR: todaySleepingHR
        ))
        return out
    }

    private func engine(_ metrics: [RecoveryEngine.DailyHealthMetric]) -> RecoveryEngine {
        RecoveryEngine(workouts: [], healthMetrics: metrics, calendar: cal, now: now)
    }

    @Test func stableNightScoresHigh() {
        let snapshot = engine(metrics()).recoverySnapshot()
        let daily = snapshot.daily
        #expect((daily.state.value ?? 0) > 0.85)
        #expect(daily.flags.isEmpty)
    }

    @Test func badNightTanksDailyButNotTrend() {
        // HRV crashes 80 → 55 ms (~ -37% in ln space), sleeping HR up 12, 5 h sleep.
        let snapshot = engine(metrics(todayHRV: 55, todaySleepingHR: 67, todaySleepMinutes: 300)).recoverySnapshot()
        let daily = snapshot.daily.state.value ?? 1
        let trend = snapshot.systemic.state.value ?? 0
        #expect(daily < 0.55)                      // acute reacts
        #expect(trend > daily + 0.15)              // trend stays calm (7-day smoothing)
        #expect(snapshot.daily.flags.contains("HRV low today"))
        #expect(snapshot.daily.flags.contains("Sleeping HR elevated"))
        #expect(snapshot.daily.flags.contains("Short sleep"))
    }

    @Test func guidanceNamesElevatedSleepingHRWhenScoreStillTrainable() {
        // HRV and sleep stay normal; only sleeping HR is elevated (55 → 66,
        // well past the ~58 bpm threshold at this baseline's variability).
        let snapshot = engine(metrics(todaySleepingHR: 66)).recoverySnapshot()
        let daily = snapshot.daily
        #expect(daily.flags.contains("Sleeping HR elevated"))
        if let score = daily.state.value, score >= 0.6 {
            #expect(daily.guidance.localizedCaseInsensitiveContains("sleeping heart rate"))
        }
    }

    /// The 1am bug: a new calendar day has started, the user hasn't slept,
    /// but Apple has already published an early daytime resting-HR estimate
    /// (awake ~69 vs a sleeping baseline of 55). That awake value must never
    /// be judged against the SLEEPING baseline — it read as a false
    /// "Sleeping HR elevated" every night the user was up past midnight.
    @Test func awakeRestingHRIsNotJudgedAgainstSleepingBaseline() {
        let m = metrics(todayHRV: nil, todaySleepingHR: nil, todaySleepMinutes: nil).map { metric in
            var copy = metric
            // History has a normal daytime resting HR alongside sleeping HR;
            // today (still awake at 1am) has ONLY the daytime estimate.
            copy.restingHR = cal.startOfDay(for: copy.date) == cal.startOfDay(for: now) ? 69 : 67
            return copy
        }
        let daily = engine(m).recoverySnapshot().daily
        #expect(!daily.flags.contains("Sleeping HR elevated"))
        // 69 vs a 67 bpm daytime baseline is within normal range — no HR
        // flag at all, and the part is labeled resting (not sleeping) HR.
        #expect(!daily.flags.contains("Resting HR elevated"))
        let hrPart = daily.parts.first { $0.name == "Resting HR" || $0.name == "Sleeping HR" }
        #expect(hrPart?.name == "Resting HR")
    }

    /// A genuinely elevated daytime resting HR (vs the daytime baseline)
    /// still flags — as resting HR, never as sleeping HR.
    @Test func daytimeRestingHRElevationFlagsHonestly() {
        let m = metrics(todayHRV: nil, todaySleepingHR: nil, todaySleepMinutes: nil).map { metric in
            var copy = metric
            copy.restingHR = cal.startOfDay(for: copy.date) == cal.startOfDay(for: now) ? 80 : 65
            return copy
        }
        let daily = engine(m).recoverySnapshot().daily
        #expect(daily.flags.contains("Resting HR elevated"))
        #expect(!daily.flags.contains("Sleeping HR elevated"))
    }

    @Test func guidanceNamesShortSleepWhenScoreStillTrainable() {
        // HRV and sleeping HR stay normal; only sleep comes up short.
        let snapshot = engine(metrics(todaySleepMinutes: 380)).recoverySnapshot()
        let daily = snapshot.daily
        #expect(daily.flags.contains("Short sleep"))
        if let score = daily.state.value, score >= 0.6 {
            #expect(daily.guidance.localizedCaseInsensitiveContains("short on sleep"))
        }
    }

    @Test func guidanceCombinesMultipleFlagsInOneSentence() {
        let snapshot = engine(metrics(todaySleepingHR: 66, todaySleepMinutes: 380)).recoverySnapshot()
        let daily = snapshot.daily
        #expect(daily.flags.contains("Sleeping HR elevated"))
        #expect(daily.flags.contains("Short sleep"))
        if let score = daily.state.value, score >= 0.6 {
            #expect(daily.guidance.localizedCaseInsensitiveContains("sleeping heart rate"))
            #expect(daily.guidance.localizedCaseInsensitiveContains("short on sleep"))
            #expect(daily.guidance.contains(" and "))
        }
    }

    /// The recommendation shown on the merged Today tile (RecoveryEngine's
    /// `report().recommendation`) must name the same flags as the daily
    /// score's own guidance — this used to only special-case HRV.
    @Test func reportRecommendationNamesNonHRVFlagsToo() {
        let report = engine(metrics(todaySleepingHR: 66)).report()
        if report.recovery.daily.flags.contains("Sleeping HR elevated"), report.displayScore >= 0.55 {
            #expect(report.recommendation.localizedCaseInsensitiveContains("sleeping heart rate"))
        }
    }

    @Test func guidanceMentionsHRVWhenFlaggedButScoreStillTrainable() {
        // Mild dip: HRV 71 vs 80 baseline, decent sleep — trainable but flagged.
        let snapshot = engine(metrics(todayHRV: 71, todaySleepMinutes: 450)).recoverySnapshot()
        let daily = snapshot.daily
        if let score = daily.state.value, score >= 0.6, daily.flags.contains("HRV low today") {
            #expect(daily.guidance.contains("HRV"))   // copy references the flag that moved the number
        }
        // Whatever the branch, guidance must never be empty for a ready score.
        #expect(daily.state.value == nil || !daily.guidance.isEmpty)
    }

    @Test func reportActionAgreesWithDisplayScore() {
        // The regression from the screenshots: caption said "HRV low" while the
        // ring was green. Action + copy must key off the same acute flags.
        let report = engine(metrics(todayHRV: 71, todaySleepMinutes: 450)).report()
        if report.recovery.daily.flags.contains("HRV low today"), report.displayScore >= 0.6 {
            #expect(report.recommendation.contains("HRV"))
        }
        // Never recommend deload while displaying a green score.
        if report.displayScore >= 0.65 {
            #expect(report.action != .deloadRecover)
        }
    }

    @Test func sleepNeedPersonalizesUpwardOnly() {
        // Habitual 9 h sleeper → need rises toward 9 h.
        let long = engine(metrics(historySleepMinutes: 540))
        #expect(long.personalizedSleepNeedMinutes() >= 520)
        // Habitual 6 h sleeper → need stays at 8 h (short sleep stays flagged).
        let short = engine(metrics(historySleepMinutes: 360))
        #expect(short.personalizedSleepNeedMinutes() == 480)
    }

    @Test func lnSpaceBandsAreScaleFree() {
        // Same relative dip at a very different absolute HRV level must score
        // the same — the point of ln-space z-scores.
        func dailyScore(baseHRV: Double, dip: Double) -> Double? {
            var m: [RecoveryEngine.DailyHealthMetric] = []
            for day in 1...40 {
                let date = cal.date(byAdding: .day, value: -day, to: now)!
                // Alternate ±5% so the baseline has realistic variance.
                let wiggle = day.isMultiple(of: 2) ? 1.05 : 0.95
                m.append(RecoveryEngine.DailyHealthMetric(
                    date: date, hrvSDNN: nil, hrvRMSSD: nil, restingHR: nil,
                    sleepTotalMinutes: 480, source: "t", hrvSampleCount: 5,
                    nocturnalHRV: baseHRV * wiggle, sleepingHR: 55))
            }
            m.append(RecoveryEngine.DailyHealthMetric(
                date: now, hrvSDNN: nil, hrvRMSSD: nil, restingHR: nil,
                sleepTotalMinutes: 480, source: "t", hrvSampleCount: 5,
                nocturnalHRV: baseHRV * dip, sleepingHR: 55))
            return engine(m).recoverySnapshot().daily.state.value
        }
        let lowBase = dailyScore(baseHRV: 40, dip: 0.8)
        let highBase = dailyScore(baseHRV: 120, dip: 0.8)
        #expect(lowBase != nil && highBase != nil)
        #expect(abs((lowBase ?? 0) - (highBase ?? 1)) < 0.03)
    }

    @Test func nocturnalPreferredOverAllDay() {
        // All-day SDNN says 100 (inflated by daytime), nocturnal says 60 — the
        // model must read 60.
        var m = metrics(todayHRV: nil)
        m[m.count - 1].hrvSDNN = 100
        m[m.count - 1].nocturnalHRV = 60
        let snapshot = engine(m).recoverySnapshot()
        #expect(snapshot.daily.flags.contains("HRV low today"))
    }
}
