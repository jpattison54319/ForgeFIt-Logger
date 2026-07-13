import ForgeData
import Foundation
import Observation
import SwiftData

/// One day's recovery and exertion reading, captured for the calendar.
struct RecoverySnapshot: Codable, Equatable {
    /// That day's ACUTE daily-readiness score, 0...1 — the pure daily number,
    /// NOT `displayScore` (which falls back to the trend when the acute isn't
    /// ready). Nil until the night's data is in.
    var daily: Double?
    /// That day's 7-day chronic recovery trend, 0...1. Nil until enough
    /// history backs it.
    var trend: Double?
    /// Same-day strain, 0...10. Nil until movement or training history backs
    /// a personal score.
    var strain: Double? = nil
    /// Historical target bounds are stored with the score so a past day keeps
    /// the exact guidance the user saw, even as today's baseline evolves.
    var strainTargetLower: Double? = nil
    var strainTargetUpper: Double? = nil

    var strainTargetRange: ClosedRange<Double>? {
        guard let strainTargetLower, let strainTargetUpper,
              strainTargetLower <= strainTargetUpper else { return nil }
        return strainTargetLower...strainTargetUpper
    }

    /// A reading worth storing has at least one real score.
    var hasData: Bool { daily != nil || trend != nil || strain != nil }
}

/// On-device history of daily recovery and strain scores, keyed by the calendar
/// day, so the training calendar can show the day's starting capacity beside
/// the exertion accumulated afterward.
///
/// Deliberately `UserDefaults`, NOT SwiftData/CloudKit: recovery is derived
/// from health data, and the privacy invariant keeps it off sync and off the
/// app's iCloud-Drive backup (which carries only logged training). Same
/// treatment as `SleepOverrideStore`.
@MainActor
@Observable
final class RecoverySnapshotStore {
    static let shared = RecoverySnapshotStore()

    // v2: v1 stored `displayScore` as the daily, which falls back to the trend
    // when the acute isn't ready — so daily == trend and every day looked the
    // same. Bumping the keys discards those bad snapshots and re-backfills with
    // the pure acute daily.
    private let defaultsKey = "recoverySnapshots.v2"
    // v3 reruns the merge-style backfill once to add strain to existing v2
    // recovery snapshots without discarding their captured daily/trend values.
    private let backfillKey = "recoverySnapshotsBackfilled.v3"
    private let calendar = Calendar.current

    /// Snapshots keyed by `startOfDay`.
    private(set) var snapshots: [Date: RecoverySnapshot] = [:]

    init() { load() }

    func snapshot(for day: Date) -> RecoverySnapshot? {
        snapshots[calendar.startOfDay(for: day)]
    }

    /// Records TODAY's live reading, overwriting so the calendar's today always
    /// matches Home's number as the score firms up through the morning. Past
    /// days are never touched by this — they keep the value captured when they
    /// were today (or the backfill).
    func recordToday(
        daily: Double?,
        trend: Double?,
        strain: Double? = nil,
        strainTarget: ClosedRange<Double>? = nil
    ) {
        let key = calendar.startOfDay(for: Date())
        var snapshot = snapshots[key] ?? RecoverySnapshot(daily: nil, trend: nil)
        // A temporarily unavailable refresh must not erase a valid reading
        // captured earlier the same day.
        snapshot.daily = daily ?? snapshot.daily
        snapshot.trend = trend ?? snapshot.trend
        snapshot.strain = strain ?? snapshot.strain
        if let strainTarget {
            snapshot.strainTargetLower = strainTarget.lowerBound
            snapshot.strainTargetUpper = strainTarget.upperBound
        }
        guard snapshot.hasData else { return }
        guard snapshots[key] != snapshot else { return }   // no redundant writes
        snapshots[key] = snapshot
        persist()
    }

    /// Stores a day's reading only if none exists — used by the backfill so it
    /// never overwrites a value the app captured live.
    func captureIfAbsent(
        day: Date,
        daily: Double?,
        trend: Double?,
        strain: Double? = nil,
        strainTarget: ClosedRange<Double>? = nil
    ) {
        let key = calendar.startOfDay(for: day)
        guard snapshots[key] == nil else { return }
        let snapshot = RecoverySnapshot(
            daily: daily,
            trend: trend,
            strain: strain,
            strainTargetLower: strainTarget?.lowerBound,
            strainTargetUpper: strainTarget?.upperBound
        )
        guard snapshot.hasData else { return }
        snapshots[key] = snapshot
        persist()
    }

    func set(_ snapshot: RecoverySnapshot, for day: Date) {
        snapshots[calendar.startOfDay(for: day)] = snapshot
        persist()
    }

    /// One-time merge backfill: recomputes retained days and fills fields that
    /// are missing. Live-captured values always win, so adding strain cannot
    /// rewrite historical recovery.
    func backfillIfNeeded(
        days: Int = 60,
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        activityMetrics: [DailyActivityMetric],
        in context: ModelContext
    ) {
        guard !UserDefaults.standard.bool(forKey: backfillKey) else { return }
        // Home can render before its asynchronous HealthKit refresh finishes.
        // Wait for that first query so walking and other daily movement are not
        // permanently omitted from the one-time historical strain backfill.
        guard HealthMetricsStore.shared.lastRefreshed != nil else { return }
        let hasCompletedWorkout = workouts.contains { $0.endedAt != nil && $0.deletedAt == nil }
        guard hasCompletedWorkout || !HealthMetricsStore.shared.metrics.isEmpty || !activityMetrics.isEmpty else { return }
        let today = calendar.startOfDay(for: Date())
        var changed = false
        for offset in 0...days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = calendar.startOfDay(for: day)
            // Recompute as-of a consistent mid-morning so each day reflects what
            // the user would have seen. Capture the ACUTE daily and the trend
            // separately — never displayScore, which conflates the two.
            let asOf = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
            let report = ReadinessReportFactory.report(workouts: workouts, exercises: exercises, in: context, now: asOf)
            let strainReport = DailyStrainEngine(
                workouts: workouts,
                activityMetrics: activityMetrics,
                dailyReadiness: report.recovery.daily.state.value,
                trendRecovery: report.recovery.systemic.state.value,
                calendar: calendar,
                now: asOf
            ).report()
            let existing = snapshots[key]
            var snapshot = existing ?? RecoverySnapshot(daily: nil, trend: nil)
            snapshot.daily = snapshot.daily ?? report.recovery.daily.state.value
            snapshot.trend = snapshot.trend ?? report.recovery.systemic.state.value
            snapshot.strain = snapshot.strain ?? strainReport.score
            snapshot.strainTargetLower = snapshot.strainTargetLower ?? strainReport.targetRange?.lowerBound
            snapshot.strainTargetUpper = snapshot.strainTargetUpper ?? strainReport.targetRange?.upperBound
            guard snapshot.hasData else { continue }   // no data that day → no calendar score
            if snapshot != existing {
                snapshots[key] = snapshot
                changed = true
            }
        }
        UserDefaults.standard.set(true, forKey: backfillKey)
        if changed { persist() }
    }

    #if DEBUG
    /// Fills the last `days` days with synthetic snapshots for previews / UI
    /// tests, so the calendar rings can be seen without real health history.
    /// Test isolation: wipe all snapshots (and their persisted copy).
    func removeAllForTesting() {
        snapshots = [:]
        UserDefaults.standard.removeObject(forKey: backfillKey)
        persist()
    }

    func seedDemo(days: Int = 40) {
        let today = calendar.startOfDay(for: Date())
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            // A gentle wave through all three colour bands so the demo shows
            // reds, ambers, and greens — and same-colour pairs.
            let phase = Double(offset)
            let daily = 0.5 + 0.42 * sin(phase / 3.1)
            let trend = 0.55 + 0.3 * sin(phase / 6.4 + 0.6)
            let strain = min(9.5, max(0.4, 5.2 + 3.4 * sin(phase / 2.7 + 0.8)))
            let targetMid = min(7.2, max(3.8, 4.8 + trend * 2.1))
            snapshots[calendar.startOfDay(for: day)] = RecoverySnapshot(
                // A couple of days have no acute daily (trend-only) to exercise
                // that ring path; older days drop the trend (daily-only).
                daily: (offset == 2 || offset == 9) ? nil : min(1, max(0.08, daily)),
                trend: offset > 34 ? nil : min(1, max(0.12, trend)),
                strain: strain,
                strainTargetLower: max(0, targetMid - 0.4),
                strainTargetUpper: min(10, targetMid + 0.4))
        }
        persist()
    }
    #endif

    // MARK: - Persistence

    private func persist() {
        let coded = snapshots.reduce(into: [String: RecoverySnapshot]()) { dict, pair in
            dict[String(pair.key.timeIntervalSince1970)] = pair.value
        }
        if let data = try? JSONEncoder().encode(coded) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let coded = try? JSONDecoder().decode([String: RecoverySnapshot].self, from: data) else { return }
        snapshots = coded.reduce(into: [Date: RecoverySnapshot]()) { dict, pair in
            if let seconds = TimeInterval(pair.key) {
                dict[Date(timeIntervalSince1970: seconds)] = pair.value
            }
        }
    }
}
