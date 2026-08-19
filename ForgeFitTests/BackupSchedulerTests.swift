import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@Suite(.serialized)
@MainActor
struct BackupSchedulerTests {
    @Test func aLogChangeAutomaticallyExportsAndRecordsSuccess() async throws {
        try await withDefaults { defaults in
            let (container, _) = try TestStore.make()
            let stamp = Date(timeIntervalSinceReferenceDate: 123_456)
            let manager = StubBackupManager(exportOutcomes: [.done(stamp)])
            let scheduler = makeScheduler(manager: manager, defaults: defaults)
            scheduler.configure(container: container)

            scheduler.noteLogDataChanged()
            await scheduler.waitForScheduledOperationForTesting()

            #expect(await manager.exportCount == 1)
            #expect(scheduler.state == .upToDate)
            #expect(scheduler.lastSuccessAt == stamp)
            #expect(defaults.object(forKey: BackupExporter.lastSuccessKey) as? Date == stamp)
        }
    }

    @Test func failedBackupStaysVisibleAndBackUpNowRetries() async throws {
        try await withDefaults { defaults in
            let (container, _) = try TestStore.make()
            let stamp = Date(timeIntervalSinceReferenceDate: 234_567)
            let manager = StubBackupManager(exportOutcomes: [
                .failed("network unavailable"),
                .done(stamp),
            ])
            let scheduler = makeScheduler(manager: manager, defaults: defaults)
            scheduler.configure(container: container)

            scheduler.noteLogDataChanged()
            await scheduler.waitForScheduledOperationForTesting()
            #expect(scheduler.state == .failed("network unavailable"))
            #expect(defaults.string(forKey: BackupScheduler.lastFailureMessageKey) == "network unavailable")

            scheduler.exportNow()
            await scheduler.waitForScheduledOperationForTesting()
            #expect(await manager.exportCount == 2)
            #expect(scheduler.state == .upToDate)
            #expect(defaults.object(forKey: BackupScheduler.lastFailureMessageKey) == nil)
            #expect(defaults.object(forKey: BackupScheduler.lastFailureAtKey) == nil)
        }
    }

    @Test func unavailableICloudHasAnExplicitRetryableState() async throws {
        try await withDefaults { defaults in
            let (container, _) = try TestStore.make()
            let manager = StubBackupManager(exportOutcomes: [.unavailable])
            let scheduler = makeScheduler(manager: manager, defaults: defaults)
            scheduler.configure(container: container)

            scheduler.exportNow()
            await scheduler.waitForScheduledOperationForTesting()

            #expect(scheduler.state == .unavailable)
            #expect(await manager.exportCount == 1)
            #expect(defaults.string(forKey: BackupScheduler.lastFailureMessageKey)?.contains("iCloud Drive") == true)
        }
    }

    @Test func deleteClearsTheSuccessStampButKeepsAutomaticBackupEnabled() async throws {
        try await withDefaults { defaults in
            let stamp = Date(timeIntervalSinceReferenceDate: 345_678)
            defaults.set(stamp, forKey: BackupExporter.lastSuccessKey)
            let manager = StubBackupManager(deletionResult: .deleted)
            let scheduler = makeScheduler(manager: manager, defaults: defaults)

            let result = await scheduler.deleteBackup()

            #expect(result == .deleted)
            #expect(await manager.deleteCount == 1)
            #expect(scheduler.state == .waitingForFirstBackup)
            #expect(scheduler.lastSuccessAt == nil)
            #expect(defaults.object(forKey: BackupExporter.lastSuccessKey) == nil)
            #expect(BackupAutomationPolicy.isEnabledInThisRelease)
        }
    }

    @Test func liveWorkoutDefersAutomaticExportUntilItCloses() async throws {
        try await withDefaults { defaults in
            let (container, _) = try TestStore.make()
            let manager = StubBackupManager(exportOutcomes: [.done(Date())])
            let scheduler = makeScheduler(manager: manager, defaults: defaults)
            scheduler.configure(container: container)
            scheduler.setLiveWorkoutActive(true)

            scheduler.noteLogDataChanged()
            await scheduler.waitForScheduledOperationForTesting()
            #expect(await manager.exportCount == 0)

            scheduler.setLiveWorkoutActive(false)
            await scheduler.waitForScheduledOperationForTesting()
            #expect(await manager.exportCount == 1)
        }
    }

    private func makeScheduler(
        manager: StubBackupManager,
        defaults: UserDefaults
    ) -> BackupScheduler {
        BackupScheduler(
            manager: manager,
            defaults: defaults,
            debounceDelay: .zero,
            foregroundResumeDelay: .zero,
            postWorkoutDelay: .zero
        )
    }

    private func withDefaults(
        _ operation: @MainActor (UserDefaults) async throws -> Void
    ) async throws {
        let suite = "BackupSchedulerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        try await operation(defaults)
    }

    private actor StubBackupManager: BackupManaging {
        private var exportOutcomes: [BackupExporter.Status]
        private let deletionResult: BackupDeletionResult
        private(set) var exportCount = 0
        private(set) var deleteCount = 0

        init(
            exportOutcomes: [BackupExporter.Status] = [],
            deletionResult: BackupDeletionResult = .deleted
        ) {
            self.exportOutcomes = exportOutcomes
            self.deletionResult = deletionResult
        }

        func exportNow(container: ModelContainer) async -> BackupExporter.Status {
            exportCount += 1
            guard !exportOutcomes.isEmpty else { return .failed("No stub outcome") }
            return exportOutcomes.removeFirst()
        }

        func deleteAllBackups() async -> BackupDeletionResult {
            deleteCount += 1
            return deletionResult
        }
    }
}
