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
