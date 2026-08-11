import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@Suite(.serialized)
@MainActor
struct PersistenceBootstrapTests {
    private enum StubError: Error {
        case unavailable
    }

    @Test func firstOpenSuccessReturnsTheRealContainer() throws {
        let expected = try TestStore.makeContainer()

        let state = PersistenceBootstrap.makeContainer(
            prepare: {},
            openSplit: { expected },
            workoutLogCanOpen: { Issue.record("Log probe must not run after a successful open"); return false },
            protectStoresFromBackup: {}
        )

        #expect(state.container === expected)
        #expect(state.failure == nil)
    }

    @Test func failedLegacyMigrationBlocksBeforeEitherStoreOpens() {
        var openAttempts = 0
        var logProbeAttempts = 0

        let state = PersistenceBootstrap.makeContainer(
            prepare: { throw StubError.unavailable },
            openSplit: {
                openAttempts += 1
                throw StubError.unavailable
            },
            workoutLogCanOpen: {
                logProbeAttempts += 1
                return true
            }
        )

        #expect(state.failure == .planMigrationUnavailable)
        #expect(openAttempts == 0)
        #expect(logProbeAttempts == 0)
    }

    @Test func unreadableWorkoutLogBlocksLaunchWithoutRetry() {
        var openAttempts = 0

        let state = PersistenceBootstrap.makeContainer(
            prepare: {},
            openSplit: {
                openAttempts += 1
                throw StubError.unavailable
            },
            workoutLogCanOpen: { false }
        )

        #expect(state.failure == .workoutLogUnavailable)
        #expect(openAttempts == 1)
    }

    @Test func splitStackFailurePreservesBothStoresWithoutRetry() {
        var openAttempts = 0

        let state = PersistenceBootstrap.makeContainer(
            prepare: {},
            openSplit: {
                openAttempts += 1
                throw StubError.unavailable
            },
            workoutLogCanOpen: { true }
        )

        #expect(state.failure == .storeStackUnavailable)
        #expect(openAttempts == 1)
    }

    @Test func failedBackupProtectionBlocksInsteadOfRunningUnprotected() throws {
        let expected = try TestStore.makeContainer()

        let state = PersistenceBootstrap.makeContainer(
            prepare: {},
            openSplit: { expected },
            workoutLogCanOpen: {
                Issue.record("Log probe must not run after the stores opened")
                return true
            },
            protectStoresFromBackup: { throw StubError.unavailable }
        )

        #expect(state.failure == .backupProtectionUnavailable)
        #expect(state.container == nil)
    }

    @Test func storeBundleReplacementStagesBeforeRemovingTheDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceBootstrapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("preserved.store")
        let destination = root.appendingPathComponent("default.store")
        try Data("source-main".utf8).write(to: source)
        try Data("source-wal".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
        try Data("old-main".utf8).write(to: destination)
        try Data("old-shm".utf8).write(to: URL(fileURLWithPath: destination.path + "-shm"))

        try PersistenceBootstrap.replaceStore(at: destination, withStoreAt: source)

        #expect(try Data(contentsOf: destination) == Data("source-main".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination.path + "-wal")) == Data("source-wal".utf8))
        #expect(!FileManager.default.fileExists(atPath: destination.path + "-shm"))
        #expect(try Data(contentsOf: source) == Data("source-main".utf8), "The preserved source must remain available for another recovery attempt")
    }
}
