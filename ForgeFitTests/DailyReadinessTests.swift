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

    /// The 1am bug, HRV edition: Apple samples awake HRV around the clock,
    /// so just past midnight the new day holds an awake spot reading (47 ms,
    /// low because the user is awake late — not because they're unrecovered)
    /// while nocturnal HRV doesn't exist yet. Scored against the sleeping
    /// baseline it tanked the daily score to ~20 until sleep synced. With no
    /// overnight evidence the daily score must wait, falling back to the
    /// (smooth) trend, and no HRV flag may fire off the awake sample.
    @Test func awakeHRVBeforeSleepSyncsDoesNotTankDailyScore() {
        let m = metrics(todayHRV: nil, todaySleepingHR: nil, todaySleepMinutes: nil).map { metric in
            var copy = metric
            if cal.startOfDay(for: copy.date) == cal.startOfDay(for: now) {
                copy.hrvSDNN = 47   // awake spot sample vs the 80 ms sleeping baseline
                copy.restingHR = 69 // Apple's early daytime resting-HR estimate
            } else {
                copy.restingHR = 67
            }
            return copy
        }
        let snapshot = engine(m).recoverySnapshot()
        #expect(snapshot.daily.state.value == nil)   // pending, not a false 20
        #expect(!snapshot.daily.flags.contains("HRV low today"))
    }

    /// Users with no sleep tracking keep their daily score: awake HRV
    /// against an awake baseline is apples-to-apples, and it's all they have.
    @Test func awakeOnlyUsersStillGetADailyScore() {
        var m: [RecoveryEngine.DailyHealthMetric] = []
        for day in 1...40 {
            m.append(RecoveryEngine.DailyHealthMetric(
                date: cal.date(byAdding: .day, value: -day, to: now)!,
                hrvSDNN: 80, hrvRMSSD: nil, restingHR: 67,
                sleepTotalMinutes: nil, source: "test", hrvSampleCount: 5,
                nocturnalHRV: nil, sleepingHR: nil
            ))
        }
        m.append(RecoveryEngine.DailyHealthMetric(
            date: now, hrvSDNN: 78, hrvRMSSD: nil, restingHR: 67,
            sleepTotalMinutes: nil, source: "test", hrvSampleCount: 5,
            nocturnalHRV: nil, sleepingHR: nil
        ))
        let daily = engine(m).recoverySnapshot().daily
        #expect((daily.state.value ?? 0) > 0.7)
    }

    /// The other 1am bug: with established baselines but tonight's sleep not
    /// yet synced, `confidence` dips below the old 0.75 display gate while
    /// the daily score is fully computable from HRV + sleeping HR — so Home
    /// claimed "Building your baseline" while the Recovery screen showed the
    /// score. Display surfaces gate on `baselineReady`, which must stay true
    /// whenever an evidence-based score exists.
    @Test func missingTonightSleepDoesNotReadAsBaselineBuilding() {
        let report = engine(metrics(todaySleepMinutes: nil)).report()
        #expect(report.recovery.daily.state.value != nil)
        #expect(report.baselineReady)
        // The scenario that exposed the bug: confidence alone would have
        // hidden a score the detail screen was already showing.
        #expect(report.confidence < 0.75)
    }

    /// With no health history and no workouts there is no evidence-based
    /// score at all — that (and only that) is the building state.
    @Test func noDataReadsAsBaselineBuilding() {
        let report = RecoveryEngine(workouts: [], healthMetrics: [], calendar: cal, now: now).report()
        #expect(!report.baselineReady)
    }

    /// A genuinely elevated daytime resting HR (vs the daytime baseline)
    /// still flags — as resting HR, never as sleeping HR. Run mid-afternoon:
    /// by then a missing overnight record means the night was missed (watch
    /// died), so the score degrades to daytime signals rather than waiting.
    @Test func daytimeRestingHRElevationFlagsHonestly() {
        let m = metrics(todayHRV: nil, todaySleepingHR: nil, todaySleepMinutes: nil).map { metric in
            var copy = metric
            copy.restingHR = cal.startOfDay(for: copy.date) == cal.startOfDay(for: now) ? 80 : 65
            return copy
        }
        let afternoon = now.addingTimeInterval(6 * 3600)
        let daily = RecoveryEngine(workouts: [], healthMetrics: m, calendar: cal, now: afternoon)
            .recoverySnapshot().daily
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

    /// The detailed daily score continues to explain its own flags, while the
    /// merged Today card delegates its action to the shared verdict policy.
    @Test func reportUsesSharedVerdictInsteadOfASecondFlagDrivenCommand() {
        let report = engine(metrics(todaySleepingHR: 66)).report()
        let expected = TodayVerdict.make(score: report.displayScore, checkinTags: [])
        #expect(report.action == expected.action)
        #expect(report.recommendation == expected.recommendation)
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
        // The regression from the screenshots: a green ring could show a
        // different command based on an independent flag. The policy owns the
        // action now, so all green scores use the same band.
        let report = engine(metrics(todayHRV: 71, todaySleepMinutes: 450)).report()
        if report.displayScore >= 0.7 && report.displayScore < 0.85 {
            #expect(report.action == .trainAsPlanned)
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
