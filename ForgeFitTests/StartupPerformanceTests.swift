import Foundation
import Testing
@testable import ForgeFit

private actor CountingHealthMetricsLoader: HealthMetricsLoading {
    private var calls = 0
    private var executedOnMainThread = false

    func load() async -> HealthMetricsRefreshResult {
        calls += 1
        executedOnMainThread = Self.currentThreadIsMain()
        try? await Task.sleep(for: .milliseconds(80))
        return HealthMetricsRefreshResult(
            daily: [],
            extras: [],
            activity: [],
            bodyweight: [],
            hrvGapDetected: false
        )
    }

    func callCount() -> Int { calls }
    func didExecuteOnMainThread() -> Bool { executedOnMainThread }

    private nonisolated static func currentThreadIsMain() -> Bool {
        Thread.isMainThread
    }
}

@MainActor
struct StartupPerformanceTests {
    @Test
    func overlappingHealthRefreshesShareOneWorkerLoad() async {
        let loader = CountingHealthMetricsLoader()
        let store = HealthMetricsStore(worker: loader)

        async let first: Void = store.refreshNow()
        async let second: Void = store.refreshNow()
        _ = await (first, second)

        #expect(await loader.callCount() == 1)
        #expect(!(await loader.didExecuteOnMainThread()))
        #expect(store.lastRefreshed != nil)
        #expect(!store.isRefreshing)
    }

    @Test
    func automaticHealthWorkoutImportThrottleSurvivesColdLaunches() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(HealthWorkoutImportPolicy.isAutomaticImportDue(
            lastAttempt: nil,
            now: now
        ))
        #expect(!HealthWorkoutImportPolicy.isAutomaticImportDue(
            lastAttempt: now.addingTimeInterval(-299),
            now: now
        ))
        #expect(HealthWorkoutImportPolicy.isAutomaticImportDue(
            lastAttempt: now.addingTimeInterval(-300),
            now: now
        ))
        #expect(!HealthWorkoutImportPolicy.isAutomaticImportDue(
            lastAttempt: now.addingTimeInterval(60),
            now: now
        ))
    }

    @Test
    func planAuditIsVersionGatedAndUsesANonMainContext() async throws {
        #expect(PlanMaintenancePolicy.needsLaunchAudit(storedVersion: 0))
        #expect(!PlanMaintenancePolicy.needsLaunchAudit(
            storedVersion: PlanMaintenancePolicy.currentVersion
        ))

        let container = try TestStore.makeContainer()
        let worker = PlanMaintenanceWorker(modelContainer: container)
        let executedOnMain = await worker.isExecutingOnMainThreadForTesting()
        #expect(!executedOnMain)

        let importExecutedOnMain = await Task.detached {
            let importWorker = HealthWorkoutImportWorker(modelContainer: container)
            return await importWorker.isExecutingOnMainThreadForTesting()
        }.value
        #expect(!importExecutedOnMain)

        let backupWorker = BackupSnapshotWorker(modelContainer: container)
        #expect(!(await backupWorker.isExecutingOnMainThreadForTesting()))
    }
}
