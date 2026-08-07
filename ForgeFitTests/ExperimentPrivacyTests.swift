import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ExperimentPrivacyTests {
    @Test func automaticICloudBackupCannotEncodeExperimentData() async throws {
        let (container, context) = try TestStore.make()
        let secret = "private-supplement-protocol-\(UUID().uuidString)"
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: secret,
            protocolDescription: secret,
            plannedEndAt: Date().addingTimeInterval(86_400)
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: secret,
            type: .note
        )
        let entry = ExperimentEntryModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            trackerID: tracker.id,
            value: .note(secret)
        )
        context.insert(experiment)
        context.insert(tracker)
        context.insert(entry)
        try context.save()

        let file = try await BackupExporter.snapshotFile(container: container)
        let data = try BackupMapper.encode(file)
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains(secret))
        #expect(!text.contains(experiment.id.uuidString))
        #expect(!text.contains(tracker.id.uuidString))
        #expect(!text.contains(entry.id.uuidString))
    }

    @Test func localStoreDirectoryIsExcludedFromOpaqueSystemBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try PersistenceBootstrap.excludeDirectoryFromSystemBackup(directory)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func deletingOneExperimentHardDeletesItsCustomGraph() throws {
        let (container, context) = try TestStore.make()
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Sensitive",
            plannedEndAt: Date().addingTimeInterval(86_400)
        )
        let tracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: "Private note",
            type: .note
        )
        let entry = ExperimentEntryModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            trackerID: tracker.id,
            value: .note("secret")
        )
        let previouslySoftDeletedEntry = ExperimentEntryModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            trackerID: tracker.id,
            value: .note("older secret"),
            deletedAt: Date()
        )
        let unrelatedExperiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Keep",
            plannedEndAt: Date().addingTimeInterval(86_400)
        )
        let unrelatedTracker = ExperimentTrackerModel(
            userID: ForgeFitDemo.userID,
            experimentID: unrelatedExperiment.id,
            label: "Keep",
            type: .note
        )
        let unrelatedEntry = ExperimentEntryModel(
            userID: ForgeFitDemo.userID,
            experimentID: unrelatedExperiment.id,
            trackerID: unrelatedTracker.id,
            value: .note("keep")
        )
        context.insert(experiment)
        context.insert(tracker)
        context.insert(entry)
        context.insert(previouslySoftDeletedEntry)
        context.insert(unrelatedExperiment)
        context.insert(unrelatedTracker)
        context.insert(unrelatedEntry)
        try context.save()

        try ExperimentUIStore.discard(
            experiment,
            trackers: [tracker],
            entries: [entry],
            in: context
        )

        #expect(
            try context.fetch(FetchDescriptor<ExperimentModel>()).map(\.id)
                == [unrelatedExperiment.id]
        )
        #expect(
            try context.fetch(FetchDescriptor<ExperimentTrackerModel>()).map(\.id)
                == [unrelatedTracker.id]
        )
        #expect(
            try context.fetch(FetchDescriptor<ExperimentEntryModel>()).map(\.id)
                == [unrelatedEntry.id]
        )
        _ = container
    }
}
