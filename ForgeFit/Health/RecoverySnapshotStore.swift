import ForgeData
import Foundation
import Observation
import SwiftData

/// Home's dashboard exactly as last rendered from live data — the four metric
/// tiles plus the recommendation hero. Cached with the day's snapshot so
/// reopening the app later the SAME day paints real numbers instantly while
/// HealthKit re-queries in the background. Strictly same-day: a new day shows
/// the loader until its own data lands, never an older day's numbers.
///
/// Values are stored as rendered (strings included) so the optimistic paint
/// can never drift from what the engines actually showed.
nonisolated struct HomeDashboardCache: Codable, Equatable, Sendable {
    // Recovery tile + recommendation hero.
    var recoveryDisplayScore: Double?
    var baselineReady: Bool
    var actionRaw: String
    var recommendation: String
    var reasonTexts: [String]
    // Sleep tile.
    var sleepValue: String
    var sleepCaption: String
    var sleepProgress: Double?
    /// The night was flagged partial-wear and not yet corrected — the tile
    /// keeps its caution tint.
    var sleepLooksPartial: Bool
    // Health tile. Strain needs no fields here: the tile rebuilds from the
    // day's `strain`/target on `RecoverySnapshot` itself.
    var healthHeadline: String
    var healthCaption: String
    var healthEvaluatedCount: Int
    var healthOutsideRangeCount: Int
    // Non-Home surfaces use the exact same finished report. Optional defaults
    // preserve decoding of caches written by older app builds.
    var preWorkoutAdjustment: String? = nil
    var readinessMethodID: String? = nil
    var readinessCoverage: Double? = nil
}

/// One day's recovery and exertion reading, captured for the calendar.
nonisolated struct RecoverySnapshot: Codable, Equatable, Sendable {
    /// That day's acute recovery-signal product index, 0...1. Nil until the
    /// current recording and source-pure baselines satisfy the v2 contract.
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
    /// Same-day Home dashboard restore payload. Only today's is ever read;
    /// never backfilled, and the calendar ignores it. Optional with a default
    /// so snapshots persisted before it existed decode unchanged.
    var dashboard: HomeDashboardCache? = nil

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

    // v2 corrected the historical daily/trend separation. Keep the storage key
    // for decode compatibility; v2 analytics provenance lives on workouts.
    private let defaultsKey = "recoverySnapshots.v2"
    // v3 reruns the merge-style backfill once to add strain to existing v2
    // recovery snapshots without discarding their captured daily/trend values.
    private let backfillKey = "recoverySnapshotsBackfilled.v3"
    private let calendar = Calendar.current

    /// Snapshots keyed by `startOfDay`.
    private(set) var snapshots: [Date: RecoverySnapshot] = [:]

    init() { load() }

    var needsBackfill: Bool {
        !UserDefaults.standard.bool(forKey: backfillKey)
    }

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
        strainTarget: ClosedRange<Double>? = nil,
        dashboard: HomeDashboardCache? = nil
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
        // The dashboard cache is "Home as last rendered from live data":
        // replaced wholesale when the caller has a live render, kept when it
        // doesn't (a pre-refresh pass must not clobber the morning's render
        // with a "building" placeholder).
        if let dashboard { snapshot.dashboard = dashboard }
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

    /// Merges a calendar projection produced by HomeAnalyticsWorker. The
    /// expensive history-wide scoring has already happened off MainActor;
    /// this method only preserves live-captured values and persists once.
    func mergeBackfill(_ candidates: [Date: RecoverySnapshot]) {
        guard needsBackfill else { return }
        var changed = false
        for (day, candidate) in candidates {
            let key = calendar.startOfDay(for: day)
            let existing = snapshots[key]
            var snapshot = existing ?? RecoverySnapshot(daily: nil, trend: nil)
            snapshot.daily = snapshot.daily ?? candidate.daily
            snapshot.trend = snapshot.trend ?? candidate.trend
            snapshot.strain = snapshot.strain ?? candidate.strain
            snapshot.strainTargetLower = snapshot.strainTargetLower
                ?? candidate.strainTargetLower
            snapshot.strainTargetUpper = snapshot.strainTargetUpper
                ?? candidate.strainTargetUpper
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

    /// UI automation: today already has a captured render, so a cold launch
    /// must paint these numbers instead of the loader.
    func seedTodayDashboardDemo() {
        set(Self.demoDaySnapshot(), for: Date())
    }

    /// UI automation: ONLY yesterday has a captured render. First open of a
    /// new day must show the loader — these values may never appear.
    func seedYesterdayDashboardDemo() {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) else { return }
        set(Self.demoDaySnapshot(), for: yesterday)
    }

    private static func demoDaySnapshot() -> RecoverySnapshot {
        RecoverySnapshot(
            daily: 0.82,
            trend: 0.64,
            strain: 5.1,
            strainTargetLower: 4.6,
            strainTargetUpper: 5.6,
            dashboard: HomeDashboardCache(
                recoveryDisplayScore: 0.82,
                baselineReady: true,
                actionRaw: RecoveryEngine.Action.trainAsPlanned.rawValue,
                recommendation: "No recovery-based restriction was detected. Use your warm-up to confirm.",
                reasonTexts: ["No adverse HRV deviation", "Sleep target met"],
                sleepValue: "7h 12m",
                sleepCaption: "Sleep target met",
                sleepProgress: 0.9,
                sleepLooksPartial: false,
                healthHeadline: "All in range",
                healthCaption: "4 health signals checked",
                healthEvaluatedCount: 4,
                healthOutsideRangeCount: 0,
                preWorkoutAdjustment: "Train as planned.",
                readinessMethodID: "recovery-index-v2",
                readinessCoverage: 1))
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
