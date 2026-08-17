import Foundation
import ForgeCore
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

/// The on-device recovery and strain snapshot store: one consistent reading
/// per day, plus compatibility with recovery-only snapshots already on device.
@MainActor
struct RecoverySnapshotStoreTests {
    private let cal = Calendar.current

    private func freshStore() -> RecoverySnapshotStore {
        let store = RecoverySnapshotStore()
        store.removeAllForTesting()   // isolate from any persisted state
        return store
    }

    @Test func clearAllErasesPersistedAndLiveRecoverySnapshots() throws {
        let suiteName = "RecoverySnapshotStoreClearTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RecoverySnapshotStore(defaults: defaults, calendar: cal)
        store.recordToday(daily: 0.82, trend: 0.64)
        defaults.set(true, forKey: RecoverySnapshotStore.backfillKey)

        #expect(defaults.data(forKey: RecoverySnapshotStore.defaultsKey) != nil)
        #expect(!store.needsBackfill)

        store.clearAll()

        #expect(store.snapshot(for: Date()) == nil)
        #expect(defaults.object(forKey: RecoverySnapshotStore.defaultsKey) == nil)
        #expect(defaults.object(forKey: RecoverySnapshotStore.backfillKey) == nil)
        let reloaded = RecoverySnapshotStore(defaults: defaults, calendar: cal)
        #expect(reloaded.snapshot(for: Date()) == nil)
        #expect(reloaded.needsBackfill)
    }

    @Test func recordTodayIsSeparateDailyAndTrendNotDisplayScore() {
        let store = freshStore()
        // The real bug: daily must be the ACUTE score, distinct from the trend —
        // never collapsed together.
        store.recordToday(daily: 1.0, trend: 0.64)
        let snap = store.snapshot(for: Date())
        #expect(snap?.daily == 1.0)
        #expect(snap?.trend == 0.64)
    }

    @Test func recordTodayOverwritesSoTodayTracksLive() {
        let store = freshStore()
        store.recordToday(daily: 0.80, trend: 0.62)   // early, pre-sync
        store.recordToday(daily: 1.00, trend: 0.64)   // acute firmed up
        let snap = store.snapshot(for: Date())
        #expect(snap?.daily == 1.00)                   // today follows the latest
        #expect(snap?.trend == 0.64)
    }

    @Test func recordTodayCarriesStrainAndItsHistoricalTarget() {
        let store = freshStore()
        store.recordToday(daily: 0.80, trend: 0.62, strain: 6.4, strainTarget: 5.8...6.8)
        let snap = store.snapshot(for: Date())
        #expect(snap?.strain == 6.4)
        #expect(snap?.strainTargetRange == 5.8...6.8)
    }

    @Test func partialRefreshDoesNotEraseCapturedStrain() {
        let store = freshStore()
        store.recordToday(daily: 0.80, trend: 0.62, strain: 6.4, strainTarget: 5.8...6.8)
        store.recordToday(daily: 0.82, trend: nil, strain: nil, strainTarget: nil)
        let snap = store.snapshot(for: Date())
        #expect(snap?.daily == 0.82)
        #expect(snap?.trend == 0.62)
        #expect(snap?.strain == 6.4)
        #expect(snap?.strainTargetRange == 5.8...6.8)
    }

    @Test func captureIfAbsentDoesNotOverwrite() {
        let store = freshStore()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        store.captureIfAbsent(day: yesterday, daily: 0.55, trend: 0.60)
        store.captureIfAbsent(day: yesterday, daily: 0.20, trend: 0.20)   // ignored
        #expect(store.snapshot(for: yesterday)?.daily == 0.55)
    }

    @Test func aReadingWithNoScoresIsNotStored() {
        let store = freshStore()
        store.recordToday(daily: nil, trend: nil)
        #expect(store.snapshot(for: Date()) == nil)
    }

    @Test func aStrainOnlyReadingIsStored() {
        let store = freshStore()
        store.recordToday(daily: nil, trend: nil, strain: 3.7)
        #expect(store.snapshot(for: Date())?.strain == 3.7)
    }

    @Test func recoveryOnlySnapshotFromPreviousVersionStillDecodes() throws {
        let data = Data(#"{"daily":0.81,"trend":0.67}"#.utf8)
        let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
        #expect(snapshot.daily == 0.81)
        #expect(snapshot.trend == 0.67)
        #expect(snapshot.strain == nil)
        #expect(snapshot.strainTargetRange == nil)
    }

    @Test func dailyOrTrendMayBeAbsentIndividually() {
        let store = freshStore()
        let d1 = cal.date(byAdding: .day, value: -1, to: Date())!
        let d2 = cal.date(byAdding: .day, value: -2, to: Date())!
        store.captureIfAbsent(day: d1, daily: 0.55, trend: nil)   // daily-only
        store.captureIfAbsent(day: d2, daily: nil, trend: 0.60)   // trend-only
        #expect(store.snapshot(for: d1)?.daily == 0.55)
        #expect(store.snapshot(for: d1)?.trend == nil)
        #expect(store.snapshot(for: d2)?.daily == nil)
        #expect(store.snapshot(for: d2)?.trend == 0.60)
    }

    @Test func backgroundBackfillMergesWithoutOverwritingCapturedScores() {
        let store = freshStore()
        let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
        store.captureIfAbsent(day: yesterday, daily: 0.82, trend: nil)

        store.mergeBackfill([
            yesterday: RecoverySnapshot(
                daily: 0.21,
                trend: 0.63,
                strain: 5.4,
                strainTargetLower: 4.8,
                strainTargetUpper: 5.8
            )
        ])

        let snapshot = store.snapshot(for: yesterday)
        #expect(snapshot?.daily == 0.82)
        #expect(snapshot?.trend == 0.63)
        #expect(snapshot?.strain == 5.4)
        #expect(snapshot?.strainTargetRange == 4.8...5.8)
    }

    // MARK: - Same-day dashboard cache

    private func demoDashboard(recommendation: String = "Green light — push today.") -> HomeDashboardCache {
        HomeDashboardCache(
            recoveryDisplayScore: 0.82,
            baselineReady: true,
            actionRaw: "push",
            recommendation: recommendation,
            reasonTexts: ["HRV above baseline"],
            sleepValue: "7h 12m",
            sleepCaption: "Sleep need met",
            sleepProgress: 0.9,
            sleepLooksPartial: false,
            healthHeadline: "All in range",
            healthCaption: "4 health signals checked",
            healthEvaluatedCount: 4,
            healthOutsideRangeCount: 0,
            vitals: VitalsTilePresentation(indicators: [
                VitalIndicatorPresentation(
                    kind: .heartRate,
                    name: "Sleeping HR",
                    valueText: "52 bpm",
                    relationText: "below usual, favorable",
                    interpretation: .favorable,
                    position: 0.82
                ),
                VitalIndicatorPresentation(
                    kind: .respiratoryRate,
                    name: "Respiratory rate",
                    valueText: "14.5 br/min",
                    relationText: "within usual band",
                    interpretation: .typical,
                    position: 0.5
                ),
                VitalIndicatorPresentation(
                    kind: .bloodOxygen,
                    name: "Blood oxygen",
                    valueText: "98%",
                    relationText: "above usual, favorable",
                    interpretation: .favorable,
                    position: 0.78
                ),
                VitalIndicatorPresentation(
                    kind: .hrv,
                    name: "HRV",
                    valueText: "66 ms",
                    relationText: "within usual band",
                    interpretation: .typical,
                    position: 0.55
                ),
            ]),
            preWorkoutAdjustment: "Train as planned.",
            readinessMethodID: "recovery-index-v2",
            readinessCoverage: 0.91)
    }

    @Test func dashboardRidesAlongWithTodaysScores() {
        let store = freshStore()
        store.recordToday(daily: 0.82, trend: 0.64, dashboard: demoDashboard())
        #expect(store.snapshot(for: Date())?.dashboard == demoDashboard())
    }

    @Test func aRecordWithoutALiveRenderKeepsTheMorningsDashboard() {
        // A cold launch records scores before its HealthKit refresh has landed
        // (dashboard nil); that pass must not clobber the same day's earlier
        // real render with nothing.
        let store = freshStore()
        store.recordToday(daily: 0.82, trend: 0.64, dashboard: demoDashboard())
        store.recordToday(daily: 0.82, trend: 0.64, dashboard: nil)
        #expect(store.snapshot(for: Date())?.dashboard == demoDashboard())
    }

    @Test func aNewRenderReplacesTheDashboardWholesale() {
        let store = freshStore()
        store.recordToday(daily: 0.82, trend: 0.64, dashboard: demoDashboard())
        var updated = demoDashboard(recommendation: "Ease off — short night.")
        updated.reasonTexts = []
        store.recordToday(daily: 0.71, trend: 0.64, dashboard: updated)
        let stored = store.snapshot(for: Date())?.dashboard
        #expect(stored?.recommendation == "Ease off — short night.")
        #expect(stored?.reasonTexts.isEmpty == true)
    }

    @Test func aScorelessDayStoresNoDashboard() {
        // No score for the day → Home keeps showing its loader; a dashboard
        // cache alone must not create a calendar day out of nothing.
        let store = freshStore()
        store.recordToday(daily: nil, trend: nil, strain: nil, dashboard: demoDashboard())
        #expect(store.snapshot(for: Date()) == nil)
    }

    @Test func dashboardSurvivesPersistenceRoundTrip() {
        let store = freshStore()
        store.recordToday(daily: 0.82, trend: 0.64, dashboard: demoDashboard())
        let reloaded = RecoverySnapshotStore()   // re-reads UserDefaults
        #expect(reloaded.snapshot(for: Date())?.dashboard == demoDashboard())
        store.removeAllForTesting()
    }

    @Test func snapshotsPersistedBeforeTheDashboardExistedStillDecode() throws {
        let data = Data(#"{"daily":0.81,"trend":0.67,"strain":5.2}"#.utf8)
        let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: data)
        #expect(snapshot.daily == 0.81)
        #expect(snapshot.dashboard == nil)
    }

    @Test func dashboardFromBeforeCrossSurfaceFieldsStillDecodes() throws {
        let data = Data(#"{"recoveryDisplayScore":0.82,"baselineReady":true,"actionRaw":"push","recommendation":"Go","reasonTexts":[],"sleepValue":"7h","sleepCaption":"Good","sleepProgress":0.9,"sleepLooksPartial":false,"healthHeadline":"All in range","healthCaption":"4 checked","healthEvaluatedCount":4,"healthOutsideRangeCount":0}"#.utf8)
        let dashboard = try JSONDecoder().decode(HomeDashboardCache.self, from: data)
        #expect(dashboard.recoveryDisplayScore == 0.82)
        #expect(dashboard.preWorkoutAdjustment == nil)
        #expect(dashboard.readinessMethodID == nil)
        #expect(dashboard.readinessCoverage == nil)
        #expect(dashboard.vitals == nil)
    }

    @Test func cachedDashboardBuildsWidgetAndWorkoutStartWithoutHistoryFetch() {
        let dashboard = demoDashboard()
        let widget = ReadinessSurfacePublisher.idleSnapshot(from: dashboard)
        #expect(widget.readinessScore == 82)
        #expect(widget.readinessAction == RecoveryEngine.Action.push.title)
        #expect(widget.readinessDetail == "Train as planned.")

        let workout = WorkoutModel(userID: ForgeFitDemo.userID, startedAt: Date())
        #expect(ReadinessSurfacePublisher.apply(dashboard, to: workout))
        #expect(workout.readinessAtStart == 82)
        #expect(workout.readinessMethodID == "recovery-index-v2")
        #expect(workout.readinessCoverageAtStart == 0.91)
    }

    @Test func delayedWorkoutStampIsIsolatedAndExactRetryPersists() throws {
        struct InjectedFailure: Error {}

        let container = try TestStore.makeContainer()
        let source = ModelContext(container)
        source.autosaveEnabled = false
        let workout = WorkoutModel(userID: ForgeFitDemo.userID, startedAt: Date())
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Committed")
        source.insert(workout)
        source.insert(routine)
        try source.save()
        routine.name = "Unrelated pending edit"

        #expect(throws: InjectedFailure.self) {
            try ReadinessSurfacePublisher.persist(
                demoDashboard(),
                to: workout.id,
                in: source,
                save: { _ in throw InjectedFailure() }
            )
        }

        var verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<WorkoutModel>()).first?.readinessAtStart == nil)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        #expect(try ReadinessSurfacePublisher.persist(
            demoDashboard(),
            to: workout.id,
            in: source
        ))
        verification = ModelContext(container)
        let persistedWorkout = try verification.fetch(FetchDescriptor<WorkoutModel>()).first
        #expect(persistedWorkout?.readinessAtStart == 82)
        #expect(persistedWorkout?.readinessMethodID == "recovery-index-v2")
        #expect(persistedWorkout?.readinessCoverageAtStart == 0.91)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Committed")

        // A second execution is harmless, and the unrelated editor state is
        // still owned by the source context until its user action saves it.
        #expect(try !ReadinessSurfacePublisher.persist(
            demoDashboard(),
            to: workout.id,
            in: source
        ))
        try source.save()
        verification = ModelContext(container)
        #expect(try verification.fetch(FetchDescriptor<RoutineModel>()).first?.name == "Unrelated pending edit")
    }
}

/// The recovery colour scale that both the calendar rings and the summary card
/// share (via `AppTheme.readinessColor`).
struct RecoveryColorBandTests {
    @Test func bandsSplitAtFortyAndSeventy() {
        let theme = AppTheme.sage
        #expect(theme.readinessColor(0.30) == theme.recoveryLow)
        #expect(theme.readinessColor(0.39) == theme.recoveryLow)
        #expect(theme.readinessColor(0.40) == theme.recoveryMid)
        #expect(theme.readinessColor(0.69) == theme.recoveryMid)
        #expect(theme.readinessColor(0.70) == theme.recoveryHigh)
        #expect(theme.readinessColor(1.00) == theme.recoveryHigh)
    }
}
