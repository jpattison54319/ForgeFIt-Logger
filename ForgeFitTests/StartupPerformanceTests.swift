import ForgeData
import Foundation
import SwiftData
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

private actor CancellableHealthMetricsLoader: HealthMetricsLoading {
    private var started = false
    private var cancellations = 0

    func load() async -> HealthMetricsRefreshResult {
        started = true
        do {
            try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
            cancellations += 1
        } catch { }
        return HealthMetricsRefreshResult(
            daily: [],
            extras: [],
            activity: [],
            bodyweight: [],
            hrvGapDetected: false
        )
    }

    func hasStarted() -> Bool { started }
    func cancellationCount() -> Int { cancellations }
}

@MainActor
struct StartupPerformanceTests {
    @Test
    func deferredLaunchMigrationsWaitForReadinessAndAnIdleForeground() {
        #expect(DeferredLaunchMaintenancePolicy.shouldSchedule(
            isPending: true,
            launchTasksFinished: true,
            allowsNonWorkoutWork: true,
            sceneIsActive: true,
            hasScheduledTask: false
        ))
        #expect(!DeferredLaunchMaintenancePolicy.shouldSchedule(
            isPending: true,
            launchTasksFinished: false,
            allowsNonWorkoutWork: true,
            sceneIsActive: true,
            hasScheduledTask: false
        ))
        #expect(!DeferredLaunchMaintenancePolicy.shouldSchedule(
            isPending: true,
            launchTasksFinished: true,
            allowsNonWorkoutWork: false,
            sceneIsActive: true,
            hasScheduledTask: false
        ))
        #expect(!DeferredLaunchMaintenancePolicy.shouldSchedule(
            isPending: true,
            launchTasksFinished: true,
            allowsNonWorkoutWork: true,
            sceneIsActive: false,
            hasScheduledTask: false
        ))
        #expect(!DeferredLaunchMaintenancePolicy.shouldSchedule(
            isPending: true,
            launchTasksFinished: true,
            allowsNonWorkoutWork: true,
            sceneIsActive: true,
            hasScheduledTask: true
        ))
    }

    @Test
    func catalogDependentMaintenanceWaitsForAPendingSeedToSucceed() {
        #expect(DeferredLaunchMaintenancePolicy.canRunCatalogDependentMaintenance(
            seedWasPending: false,
            seedSucceeded: false
        ))
        #expect(!DeferredLaunchMaintenancePolicy.canRunCatalogDependentMaintenance(
            seedWasPending: true,
            seedSucceeded: false
        ))
        #expect(DeferredLaunchMaintenancePolicy.canRunCatalogDependentMaintenance(
            seedWasPending: true,
            seedSucceeded: true
        ))
    }

    @Test
    func launchLoggerWaitsForTheReadyForegroundShellAndActiveRow() {
        #expect(LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: true,
            launchTasksFinished: true,
            presentationHostMounted: true,
            sceneIsActive: true,
            onboardingPresented: false,
            hasActiveWorkout: true
        ))
        #expect(!LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: true,
            launchTasksFinished: false,
            presentationHostMounted: true,
            sceneIsActive: true,
            onboardingPresented: false,
            hasActiveWorkout: true
        ))
        #expect(!LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: true,
            launchTasksFinished: true,
            presentationHostMounted: true,
            sceneIsActive: false,
            onboardingPresented: false,
            hasActiveWorkout: true
        ))
        #expect(!LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: true,
            launchTasksFinished: true,
            presentationHostMounted: true,
            sceneIsActive: true,
            onboardingPresented: false,
            hasActiveWorkout: false
        ))
        #expect(!LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: false,
            launchTasksFinished: true,
            presentationHostMounted: true,
            sceneIsActive: true,
            onboardingPresented: false,
            hasActiveWorkout: true
        ))
        #expect(!LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: true,
            launchTasksFinished: true,
            presentationHostMounted: true,
            sceneIsActive: true,
            onboardingPresented: true,
            hasActiveWorkout: true
        ))
        #expect(!LaunchLoggerPresentationPolicy.shouldPresent(
            isPending: true,
            launchTasksFinished: true,
            presentationHostMounted: false,
            sceneIsActive: true,
            onboardingPresented: false,
            hasActiveWorkout: true
        ))
    }

    @Test
    func staleRemovedWorkoutCannotCancelNewAutoStartPresentation() {
        let oldWorkoutID = UUID()
        let newWorkoutID = UUID()

        #expect(!LaunchLoggerPresentationPolicy.shouldClearPendingPresentation(
            pendingWorkoutID: newWorkoutID,
            removedWorkoutID: oldWorkoutID
        ))
        #expect(LaunchLoggerPresentationPolicy.shouldClearPendingPresentation(
            pendingWorkoutID: newWorkoutID,
            removedWorkoutID: newWorkoutID
        ))
        #expect(LaunchLoggerPresentationPolicy.shouldClearPendingPresentation(
            pendingWorkoutID: nil,
            removedWorkoutID: oldWorkoutID
        ))
    }

    @Test @MainActor
    func targetedLoggerResolutionIgnoresAStaleQueryCandidate() throws {
        let container = try TestStore.makeContainer()
        let mainContext = ModelContext(container)
        mainContext.autosaveEnabled = false
        let oldWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Old active workout",
            startedAt: .now.addingTimeInterval(-600)
        )
        mainContext.insert(oldWorkout)
        try mainContext.save()

        let replacementContext = ModelContext(container)
        replacementContext.autosaveEnabled = false
        let oldID = oldWorkout.id
        var oldDescriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == oldID }
        )
        oldDescriptor.fetchLimit = 1
        if let durableOld = try replacementContext.fetch(oldDescriptor).first {
            replacementContext.delete(durableOld)
        }
        let newWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "New active workout",
            startedAt: .now
        )
        replacementContext.insert(newWorkout)
        try replacementContext.save()

        let resolved = LaunchLoggerWorkoutResolver.resolve(
            preferredID: newWorkout.id,
            queryCandidate: oldWorkout,
            in: mainContext
        )
        #expect(resolved?.id == newWorkout.id)

        let missing = LaunchLoggerWorkoutResolver.resolve(
            preferredID: UUID(),
            queryCandidate: oldWorkout,
            in: mainContext
        )
        #expect(missing == nil)
    }

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
    func liveWorkoutCancelsTheOwnedHealthRefreshWithoutPublishing() async {
        let loader = CancellableHealthMetricsLoader()
        let store = HealthMetricsStore(worker: loader)
        let refresh = Task { await store.refreshNow() }

        for _ in 0..<1_000 {
            if await loader.hasStarted() { break }
            await Task.yield()
        }
        #expect(await loader.hasStarted())

        store.setLiveWorkoutActive(true)
        await refresh.value

        #expect(await loader.cancellationCount() == 1)
        #expect(store.lastRefreshed == nil)
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
