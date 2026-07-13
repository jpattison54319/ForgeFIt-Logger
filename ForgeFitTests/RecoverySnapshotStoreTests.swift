import Foundation
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
