import ForgeCore
import ForgeData
import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps every lightweight readiness surface on Home's single finished
/// analytics result. Launch, foreground, Watch sync, and workout start never
/// rebuild workout history on MainActor.
@MainActor
enum ReadinessSurfacePublisher {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

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

    /// Persists the delayed workout-start stamp without saving or rolling back
    /// unrelated edits held by the screen's shared ModelContext.
    @discardableResult
    static func persistCachedStart(
        to workoutID: UUID,
        in sourceContext: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> Bool {
        guard let dashboard = currentDashboard(now: now) else { return false }
        return try persist(
            dashboard,
            to: workoutID,
            in: sourceContext,
            save: save
        )
    }

    /// Internal overload keeps the transaction boundary directly testable
    /// without coupling persistence tests to the singleton snapshot cache.
    @discardableResult
    static func persist(
        _ dashboard: HomeDashboardCache,
        to workoutID: UUID,
        in sourceContext: ModelContext,
        save: SaveOperation = { try $0.save() }
    ) throws -> Bool {
        let transaction = ModelContext(sourceContext.container)
        transaction.autosaveEnabled = false
        let targetID = workoutID
        var descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        guard let workout = try transaction.fetch(descriptor).first,
              workout.deletedAt == nil,
              workout.readinessAtStart == nil,
              apply(dashboard, to: workout) else {
            return false
        }
        try save(transaction)
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
