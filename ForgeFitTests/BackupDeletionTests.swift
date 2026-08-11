import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-007: reset-time backup deletion must be awaited and reported, never
/// fire-and-forget. Deployment paths are driven through an injected
/// `BackupDeleting` seam so success, offline/unavailable, failure, and
/// interruption are deterministic without touching iCloud. The exporter's own
/// success/failure/cancellation behavior is covered against a temp-directory
/// override.
///
/// Serialized: `resetAllAppData` mutates process-wide state (clears resettable
/// defaults, resets `Fmt` units, seeds the library), so these tests restore
/// the pre-test snapshot and never run concurrently with each other.
@Suite(.serialized)
@MainActor
struct BackupDeletionTests {
    // MARK: - Reset orchestration (injected seam)

    @Test func resetCompletesWhenBackupDeletionSucceeds() async throws {
        try await withPrefsSnapshot {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            let deleter = CountingDeleter(result: .deleted)
            let capture = NotificationCapture()
            capture.start(.forgeFitAccountResetDidComplete)
            defer { capture.stop() }

            let outcome = try await AccountResetService.resetAllAppData(in: context, backupDeleter: deleter)

            #expect(outcome == .completed)
            #expect(deleter.callCount == 1, "reset must await the deletion, not fire it and forget it")
            #expect(capture.count == 1, "completion must be posted only after the deletion result is known")
        }
    }

    @Test func resetHoldsCompletionWhenBackupCannotBeReached() async throws {
        try await withPrefsSnapshot {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            let capture = NotificationCapture()
            capture.start(.forgeFitAccountResetDidComplete)
            defer { capture.stop() }

            let outcome = try await AccountResetService.resetAllAppData(
                in: context,
                backupDeleter: StubBackupDeleter(result: .unavailable)
            )

            // Unavailable means "we could not look", not "nothing existed":
            // the backup may still exist, so this is an unresolved consequence,
            // never a completed reset.
            #expect(outcome == .backupDeletionUnavailable)
            #expect(capture.count == 0, "the shell must not transition until the user acknowledged the unresolved backup")
        }
    }

    @Test func resetHoldsCompletionWhenBackupDeletionFails() async throws {
        try await withPrefsSnapshot {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            let capture = NotificationCapture()
            capture.start(.forgeFitAccountResetDidComplete)
            defer { capture.stop() }

            let outcome = try await AccountResetService.resetAllAppData(
                in: context,
                backupDeleter: StubBackupDeleter(result: .failed("offline"))
            )

            #expect(outcome == .backupDeletionFailed("offline"))
            #expect(capture.count == 0, "the shell must not transition until the user acknowledged the failure")
        }
    }

    @Test func resetHoldsCompletionWhenBackupDeletionIsInterrupted() async throws {
        try await withPrefsSnapshot {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            let capture = NotificationCapture()
            capture.start(.forgeFitAccountResetDidComplete)
            defer { capture.stop() }

            let outcome = try await AccountResetService.resetAllAppData(
                in: context,
                backupDeleter: StubBackupDeleter(result: .cancelled)
            )

            #expect(outcome == .backupDeletionCancelled)
            #expect(capture.count == 0, "the shell must not transition until the user acknowledged the interruption")
        }
    }

    @Test func completionPostsOnlyAfterExplicitAcknowledgementOfFailure() async throws {
        try await withPrefsSnapshot {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            let capture = NotificationCapture()
            capture.start(.forgeFitAccountResetDidComplete)
            defer { capture.stop() }

            _ = try await AccountResetService.resetAllAppData(
                in: context,
                backupDeleter: StubBackupDeleter(result: .failed("coordinator"))
            )
            #expect(capture.count == 0)

            // Simulates the user tapping the consequence-stated Continue action.
            AccountResetService.finishResetAfterBackupDeletionFailure()

            #expect(capture.count == 1, "only the acknowledged failure may release the onboarding transition")
        }
    }

    @Test func completionPostsOnlyAfterExplicitAcknowledgementOfUnavailableDeletion() async throws {
        try await withPrefsSnapshot {
            let (container, context) = try TestStore.make()
            defer { _ = container }
            let capture = NotificationCapture()
            capture.start(.forgeFitAccountResetDidComplete)
            defer { capture.stop() }

            _ = try await AccountResetService.resetAllAppData(
                in: context,
                backupDeleter: StubBackupDeleter(result: .unavailable)
            )
            #expect(capture.count == 0)

            AccountResetService.finishResetAfterBackupDeletionFailure()

            #expect(capture.count == 1, "only the acknowledged unresolved backup may release the onboarding transition")
        }
    }

    // MARK: - BackupExporter deletion semantics (temp-dir override)

    @Test func deleteReportsDeletedAndClearsStampOnlyOnSuccess() async throws {
        let dir = try makeTempBackupDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = BackupExporter(directoryOverride: dir)
        try await writeBackupFiles(in: dir, exporter: exporter)
        UserDefaults.standard.set(Date(), forKey: BackupExporter.lastSuccessKey)
        defer { UserDefaults.standard.removeObject(forKey: BackupExporter.lastSuccessKey) }

        let result = await exporter.deleteAllBackups()

        #expect(result == .deleted)
        let latest = try #require(await exporter.latestBackupURL())
        let previous = try #require(await exporter.previousBackupURL())
        #expect(!FileManager.default.fileExists(atPath: latest.path))
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(UserDefaults.standard.object(forKey: BackupExporter.lastSuccessKey) == nil)
        #expect(await exporter.status == .idle)
    }

    @Test func deleteReportsFailureKeepsFailureStatusAndKeepsStamp() async throws {
        let dir = try makeTempBackupDirectory()
        defer {
            // Restore permissions so the fixture directory is removable.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let exporter = BackupExporter(directoryOverride: dir)
        try await writeBackupFiles(in: dir, exporter: exporter)
        UserDefaults.standard.set(Date(), forKey: BackupExporter.lastSuccessKey)
        defer { UserDefaults.standard.removeObject(forKey: BackupExporter.lastSuccessKey) }
        // A read-only directory makes the coordinated removal fail
        // deterministically (no write permission on the parent).
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let result = await exporter.deleteAllBackups()

        guard case .failed = result else {
            Issue.record("Expected deletion to fail against a read-only directory, got \(result)")
            return
        }
        let status = await exporter.status
        #expect(status != .idle, "a failed delete must never report back as idle")
        guard case .failed = status else {
            Issue.record("Status must be .failed after a failed delete, got \(status)")
            return
        }
        #expect(
            UserDefaults.standard.object(forKey: BackupExporter.lastSuccessKey) != nil,
            "the success stamp must survive a failed delete"
        )
    }

    @Test func deleteReportsCancellationWhenInterrupted() async throws {
        let dir = try makeTempBackupDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = BackupExporter(directoryOverride: dir)
        try await writeBackupFiles(in: dir, exporter: exporter)
        UserDefaults.standard.set(Date(), forKey: BackupExporter.lastSuccessKey)
        defer { UserDefaults.standard.removeObject(forKey: BackupExporter.lastSuccessKey) }

        // Cancel synchronously before the child task can run its first line:
        // the exporter's first check is Task.isCancelled, so the outcome is
        // deterministic and the actor never reaches the removal.
        let task = Task { await exporter.deleteAllBackups() }
        task.cancel()
        let result = await task.value

        #expect(result == .cancelled)
        guard case .failed = await exporter.status else {
            Issue.record("an interrupted delete must leave an explicit non-idle failure status")
            return
        }
        #expect(
            UserDefaults.standard.object(forKey: BackupExporter.lastSuccessKey) != nil,
            "an interrupted delete must preserve the previous success stamp"
        )
    }

    @Test func deleteReportsDeletedWhenNoBackupFilesExist() async throws {
        let dir = try makeTempBackupDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = BackupExporter(directoryOverride: dir)

        let result = await exporter.deleteAllBackups()

        #expect(result == .deleted, "nothing to delete is a successful deletion")
        #expect(await exporter.status == .idle)
    }

    // MARK: - User-facing copy

    @Test func backupFailureCopyStatesConsequenceAndNeverReassures() {
        // Every non-success outcome (failed, interrupted, unreachable) must
        // surface the same consequence pattern: backup may remain + visible
        // recovery path, and never a claim that it was deleted/removed.
        let copies = [
            ResetDataSheet.backupDeletionFailedCopy,
            ResetDataSheet.backupDeletionCancelledCopy,
            ResetDataSheet.backupDeletionUnavailableCopy,
        ]
        for copy in copies {
            #expect(copy.contains("may still exist"), "consequence copy must state the backup may remain")
            #expect(copy.contains("Backups"), "copy must point at the visible recovery path")
            #expect(copy.contains("Files"))
            #expect(!copy.contains("was deleted"), "copy must never claim the backup was deleted")
            #expect(!copy.contains("removed"), "copy must never reassure that the backup was removed")
        }
    }

    // MARK: - Mirrored privacy copy

    @Test func privacyPolicyDeletionWordingIsMirroredAndConsequenceAware() throws {
        let phrase = "attempts to remove it and tells you if it could not"
        let viewSource = try readRepoFile(
            "ForgeFit", "Settings", "PrivacyPolicyView.swift",
            file: #filePath
        )
        let docs = try readRepoFile("docs", "privacy-policy.md", file: #filePath)
        #expect(normalized(viewSource).contains(normalized(phrase)))
        #expect(normalized(docs).contains(normalized(phrase)))
    }

    // MARK: - Fixtures

    private struct StubBackupDeleter: BackupDeleting, Sendable {
        let result: BackupDeletionResult
        func deleteAllBackups() async -> BackupDeletionResult { result }
    }

    /// Counts invocations so the tests can prove the reset awaited the
    /// deletion instead of detaching it.
    private final class CountingDeleter: BackupDeleting, @unchecked Sendable {
        let result: BackupDeletionResult
        private let lock = NSLock()
        private var _callCount = 0

        init(result: BackupDeletionResult) {
            self.result = result
        }

        var callCount: Int {
            lock.withLock { _callCount }
        }

        func deleteAllBackups() async -> BackupDeletionResult {
            lock.withLock { _callCount += 1 }
            return result
        }
    }

    /// Observes notifications at the posting site (queue: nil runs the block
    /// on the posting thread), so counts are settled synchronously after the
    /// awaited call returns.
    private final class NotificationCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        private var token: NSObjectProtocol?

        func start(_ name: Notification.Name) {
            token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] _ in
                self?.lock.lock()
                self?._count += 1
                self?.lock.unlock()
            }
        }

        func stop() {
            if let token {
                NotificationCenter.default.removeObserver(token)
            }
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return _count
        }
    }

    private func makeTempBackupDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FF-007-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeBackupFiles(in dir: URL, exporter: BackupExporter) async throws {
        let latest = try #require(await exporter.latestBackupURL())
        let previous = try #require(await exporter.previousBackupURL())
        try Data("latest".utf8).write(to: latest)
        try Data("previous".utf8).write(to: previous)
    }

    /// `resetAllAppData` clears every resettable defaults key and resets the
    /// `Fmt` unit globals; restore the snapshot so parallel suites observe the
    /// same prefs as before.
    private func withPrefsSnapshot<Result>(
        _ body: () async throws -> Result
    ) async throws -> Result {
        let defaults = UserDefaults.standard
        let snapshot = AppPreferenceKeys.allResettable.map { ($0, defaults.object(forKey: $0)) }
        let unit = Fmt.unit
        let distanceUnit = Fmt.distanceUnit
        defer {
            for (key, value) in snapshot {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            Fmt.unit = unit
            Fmt.distanceUnit = distanceUnit
        }
        return try await body()
    }

    private func readRepoFile(_ components: String..., file: String) throws -> String {
        // #filePath is the test source on the host; walking up two levels
        // from ForgeFitTests/ lands on the repository root.
        let repoRoot = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = components.reduce(repoRoot) { $0.appendingPathComponent($1) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
