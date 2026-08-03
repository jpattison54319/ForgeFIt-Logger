import ForgeCore
import ForgeData
import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps every lightweight readiness surface on Home's single finished
/// analytics result. Launch, foreground, Watch sync, and workout start never
/// rebuild workout history on MainActor.
@MainActor
enum ReadinessSurfacePublisher {
    static func currentDashboard(now: Date = .now) -> HomeDashboardCache? {
        RecoverySnapshotStore.shared.snapshot(for: now)?.dashboard
    }

    static func idleSnapshot(from dashboard: HomeDashboardCache) -> ForgeFitWidgetSnapshot {
        ForgeFitWidgetSnapshot(
            mode: .idle,
            readinessScore: dashboard.recoveryDisplayScore.map { Int(($0 * 100).rounded()) },
            readinessAction: RecoveryEngine.Action(rawValue: dashboard.actionRaw)?.title,
            readinessDetail: dashboard.preWorkoutAdjustment ?? dashboard.recommendation,
            reasonChips: Array(dashboard.reasonTexts.prefix(3))
        )
    }

    static func publishFresh(_ report: RecoveryEngine.Report) {
        publish(ForgeFitWidgetSnapshot(
            mode: .idle,
            readinessScore: report.displayScore.map { Int(($0 * 100).rounded()) },
            readinessAction: report.action.title,
            readinessDetail: report.preWorkoutAdjustment,
            reasonChips: Array(report.reasonChips.prefix(3).map(\.text))
        ))
    }

    /// Uses only today's persisted dashboard. A missing score remains missing;
    /// starting a workout must never make the logger wait for analytics.
    @discardableResult
    static func applyCachedStart(to workout: WorkoutModel, now: Date = .now) -> Bool {
        guard let dashboard = currentDashboard(now: now) else { return false }
        return apply(dashboard, to: workout)
    }

    @discardableResult
    static func apply(_ dashboard: HomeDashboardCache, to workout: WorkoutModel) -> Bool {
        guard let displayScore = dashboard.recoveryDisplayScore else { return false }
        workout.readinessAtStart = Int((displayScore * 100).rounded())
        workout.readinessMethodID = dashboard.readinessMethodID
        workout.readinessCoverageAtStart = dashboard.readinessCoverage
        return true
    }

    static func publish(_ snapshot: ForgeFitWidgetSnapshot) {
        if let existing = ForgeFitWidgetSnapshotStore.load() {
            var comparison = snapshot
            comparison.updatedAt = existing.updatedAt
            guard comparison != existing else { return }
        }
        ForgeFitWidgetSnapshotStore.save(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }
}
