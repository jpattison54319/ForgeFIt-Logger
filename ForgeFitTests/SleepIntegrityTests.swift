import Foundation
import Testing
@testable import ForgeFit

/// The partial-wear detection and its honest-fallback contract: a forgotten
/// watch must read as a data gap (lower confidence, no penalty, no debt), while
/// a genuinely short night still counts as short sleep.
struct SleepIntegrityTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A night `daysAgo` back with the given sleep + coverage. Bed/wake anchors
    /// default to a habitual 23:00 → 07:00 unless overridden.
    private func night(
        daysAgo: Int,
        sleepMinutes: Int?,
        hrvSamples: Int? = 40,
        hrSamples: Int? = 60,
        bedHour: Int = 23,
        wakeHour: Int = 7
    ) -> RecoveryEngine.DailyHealthMetric {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now)!
        let start = cal.date(bySettingHour: bedHour, minute: 0, second: 0, of: cal.date(byAdding: .day, value: -1, to: day)!)!
        let end = cal.date(bySettingHour: wakeHour, minute: 0, second: 0, of: day)!
        return RecoveryEngine.DailyHealthMetric(
            date: day, hrvSDNN: 60, hrvRMSSD: nil, restingHR: 58,
            sleepTotalMinutes: sleepMinutes, source: "test",
            hrvSampleCount: hrvSamples, nocturnalHRV: 65, sleepingHR: 52,
            sleepingHRSampleCount: hrSamples,
            sleepStart: sleepMinutes == nil ? nil : start,
            sleepEnd: sleepMinutes == nil ? nil : end
        )
    }

    /// 20 stable 8 h nights plus a configurable "last night".
    private func series(lastNight: RecoveryEngine.DailyHealthMetric) -> [RecoveryEngine.DailyHealthMetric] {
        var out = (1...20).map { night(daysAgo: $0, sleepMinutes: 480) }
        out.append(lastNight)
        return out
    }

    // MARK: - Detection

    @Test func partialWearFlaggedBySparseCoverage() {
        // 2 h of sleep with only a fragment of samples = forgotten watch.
        let last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 2, hrSamples: 3)
        let annotated = SleepIntegrity.annotate(series(lastNight: last))
        #expect(annotated.last?.sleepLikelyPartial == true)
        #expect(annotated.last?.sleepIsTrustworthy == false)
    }

    @Test func partialWearFlaggedByLateAnchor() {
        // Watch put on at 5am: dense samples in the fragment, but the window is
        // anchored hours from the habitual 23:00 bedtime.
        let last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 30, hrSamples: 40, bedHour: 5, wakeHour: 7)
        let annotated = SleepIntegrity.annotate(series(lastNight: last))
        #expect(annotated.last?.sleepLikelyPartial == true)
    }

    @Test func genuineShortNightNotFlagged() {
        // A real 3 h night: short, but DENSE samples across a normally-anchored
        // window. This must stay a real short night, not get suppressed.
        let last = night(daysAgo: 0, sleepMinutes: 180, hrvSamples: 30, hrSamples: 45, bedHour: 23, wakeHour: 2)
        let annotated = SleepIntegrity.annotate(series(lastNight: last))
        #expect(annotated.last?.sleepLikelyPartial == false)
    }

    @Test func normalNightNotFlagged() {
        let last = night(daysAgo: 0, sleepMinutes: 470, hrvSamples: 40, hrSamples: 60)
        let annotated = SleepIntegrity.annotate(series(lastNight: last))
        #expect(annotated.last?.sleepLikelyPartial == false)
    }

    @Test func noBaselineMeansNoFlag() {
        // Too few prior nights to know what's normal — never flag.
        let last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 1, hrSamples: 1)
        let short = [night(daysAgo: 1, sleepMinutes: 480), night(daysAgo: 2, sleepMinutes: 480), last]
        let annotated = SleepIntegrity.annotate(short)
        #expect(annotated.last?.sleepLikelyPartial == false)
    }

    // MARK: - Metric gating

    @Test func partialNightDropsNocturnalCardiacInFavorOfAllDay() {
        var m = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 2, hrSamples: 3)
        m.integrityFlags.insert(SleepIntegrity.Flag.partialWear)
        // Nocturnal fragment ignored; all-day resting HR / HRV lead instead.
        #expect(m.bestRestingHR == 58)          // restingHR, not sleepingHR 52
        #expect(m.bestHRV == 60)                 // hrvSDNN, not nocturnalHRV 65
    }

    @Test func trustworthyNightKeepsNocturnalCardiac() {
        let m = night(daysAgo: 0, sleepMinutes: 470)
        #expect(m.bestRestingHR == 52)           // sleepingHR preferred
        #expect(m.bestHRV == 65)                 // nocturnalHRV preferred
    }

    // MARK: - Engine fallback

    private func engine(_ metrics: [RecoveryEngine.DailyHealthMetric]) -> RecoveryEngine {
        RecoveryEngine(workouts: [], healthMetrics: metrics, calendar: cal, now: now)
    }

    @Test func partialNightExcludedFromSleepDebt() {
        let last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 2, hrSamples: 3)
        let annotated = SleepIntegrity.annotate(series(lastNight: last))
        // All history is 8 h (need met), so a trustworthy series has ~0 debt.
        // The 2 h fragment, if counted, would inject ~6 h — excluding it keeps
        // debt at zero.
        #expect(engine(annotated).sleepDebtHours() == 0)
    }

    @Test func partialNightDoesNotCapReadinessOrChargeDebt() {
        let last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 2, hrSamples: 3)
        let flagged = engine(SleepIntegrity.annotate(series(lastNight: last))).report()
        // Same series but the fragment TRUSTED (pretend it's real 2 h sleep).
        let trustedSeries = series(lastNight: night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 40, hrSamples: 60, bedHour: 23, wakeHour: 1))
        let trusted = engine(trustedSeries).report()
        // The honest fallback must not report a worse score than trusting a
        // real short night would — a data gap is never a bigger deficit than
        // measured short sleep.
        #expect(flagged.score >= trusted.score)
        #expect(flagged.missingInputs.contains("Sleep (partial)"))
        #expect(!flagged.reasonChips.contains { $0.text == "Sleep debt" })
    }

    // MARK: - Corrections

    @Test @MainActor func demoSeedProducesHomeAlert() {
        HealthMetricsStore.shared.seedPartialSleepDemo()
        let alert = HealthMetricsStore.shared.partialSleepAlert
        #expect(alert != nil)
        #expect(alert?.capturedMinutes == 120)
    }

    @Test @MainActor func sleepChoicesSurviveStoreRecreation() throws {
        let suiteName = "SleepOverrideStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Construct once before saving, matching the real app lifecycle. This
        // also completes the one-time legacy repair before any new choice is
        // made, so a later launch must preserve every current action type.
        let store = SleepOverrideStore(defaults: defaults, calendar: cal)
        let choices: [SleepNightOverride] = [
            .confirmed,
            .manual(minutes: 450),
            .untracked,
        ]
        let days = choices.indices.map { cal.date(byAdding: .day, value: -$0, to: now)! }
        for (day, choice) in zip(days, choices) {
            store.set(choice, for: day)
        }

        let reloaded = SleepOverrideStore(defaults: defaults, calendar: cal)
        for (day, choice) in zip(days, choices) {
            #expect(reloaded.override(for: day) == choice)
        }
    }

    @Test func manualOverrideSubstitutesDurationAndClearsFlag() {
        let last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 2, hrSamples: 3)
        var series = series(lastNight: last)
        // Simulate the store's manual correction inline (pure transform).
        let day = cal.startOfDay(for: now)
        series = series.map { m in
            guard cal.isDate(m.date, inSameDayAs: day) else { return m }
            var copy = m
            copy.integrityFlags.insert(SleepIntegrity.Flag.userCorrected)
            copy.sleepTotalMinutes = 450
            return copy
        }
        let annotated = SleepIntegrity.annotate(series)
        let corrected = annotated.first { cal.isDate($0.date, inSameDayAs: day) }
        #expect(corrected?.sleepUserCorrected == true)
        #expect(corrected?.sleepTotalMinutes == 450)
        // A user-vouched night is trustworthy again.
        #expect(corrected?.sleepIsTrustworthy == true)
    }

    @Test @MainActor func recoveryLabelsConfirmedSleepInsteadOfCallingItPartial() throws {
        var last = night(daysAgo: 0, sleepMinutes: 120, hrvSamples: 2, hrSamples: 3)
        last.sleepOverride = .confirmed
        last.integrityFlags.insert(SleepIntegrity.Flag.userCorrected)

        let part = try #require(
            engine(series(lastNight: last)).recoverySnapshot().daily.parts
                .first { $0.name == "Sleep (last night)" }
        )

        #expect(part.sleepOverrideStatus == .confirmed)
        #expect(part.detailText.contains("Confirmed by you"))
        #expect(!part.detailText.contains("part of the night"))
    }

    @Test @MainActor func recoveryLabelsManuallyEditedSleep() throws {
        var last = night(daysAgo: 0, sleepMinutes: 450, hrvSamples: 2, hrSamples: 3)
        last.sleepOverride = .manual(minutes: 450)
        last.integrityFlags.insert(SleepIntegrity.Flag.userCorrected)

        let part = try #require(
            engine(series(lastNight: last)).recoverySnapshot().daily.parts
                .first { $0.name == "Sleep (last night)" }
        )

        #expect(part.sleepOverrideStatus == .edited)
        #expect(part.valueText.contains("7.5"))
        #expect(part.detailText.contains("Edited by you"))
    }

    @Test @MainActor func recoveryLabelsUntrackedSleepAsIntentionalExclusion() throws {
        var last = night(daysAgo: 0, sleepMinutes: nil, hrvSamples: 2, hrSamples: 3)
        last.nocturnalHRV = nil
        last.sleepingHR = nil
        last.sleepOverride = .untracked
        last.integrityFlags.insert(SleepIntegrity.Flag.userCorrected)
        let metrics = series(lastNight: last)

        let report = engine(metrics).report()
        let part = try #require(
            report.recovery.daily.parts.first { $0.name == "Sleep (last night)" }
        )
        let signal = try #require(report.signals.first { $0.name == "Sleep" })
        let buildingText: String?
        if case .building(let text) = part.state {
            buildingText = text
        } else {
            buildingText = nil
        }

        #expect(part.sleepOverrideStatus == .notTracked)
        #expect(buildingText == "Excluded at your request")
        #expect(signal.detail == "Not tracked for this night at your request")
        #expect(!signal.detail.contains("part of the night"))
        #expect(report.reasonChips.contains { $0.text == "Sleep excluded by you" })
    }

    // MARK: - Statistics

    @Test func percentileInterpolates() {
        let sorted = [100, 200, 300, 400, 500]
        #expect(SleepIntegrity.percentile(sorted, 0.0) == 100)
        #expect(SleepIntegrity.percentile(sorted, 0.5) == 300)
        #expect(SleepIntegrity.percentile(sorted, 1.0) == 500)
    }

    @Test func circularMedianHandlesMidnightWrap() {
        // Bedtimes at 23:00, 23:30, 00:00, 00:30 → median near midnight, not noon.
        let minutes = [23 * 60, 23 * 60 + 30, 0, 30]
        let median = SleepIntegrity.circularMedianMinute(minutes)
        // Any of the near-midnight samples is a valid circular median; the bug
        // being guarded is a linear mean landing around 11:45 (705).
        #expect(SleepIntegrity.circularDistanceMinutes(median, 0) <= 30)
    }
}
