import Foundation
import Testing
@testable import ForgeFit

struct BackupRotationTests {
    private enum InjectedFailure: Error {
        case atBoundary
    }

    @Test func successfulRotationKeepsNewLatestAndPriorPrevious() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let latest = directory.appendingPathComponent("latest")
        let previous = directory.appendingPathComponent("previous")
        let old = Data("old-latest".utf8)
        let new = Data("new-latest".utf8)
        try old.write(to: latest)
        try Data("older-previous".utf8).write(to: previous)

        try BackupFileRotation.rotate(
            newData: new,
            latestURL: latest,
            previousURL: previous
        )

        #expect(try Data(contentsOf: latest) == new)
        #expect(try Data(contentsOf: previous) == old)
    }

    @Test func failureAtEveryBoundaryAlwaysLeavesARecoverableLatest() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Data("old-latest".utf8)
        let new = Data("new-latest".utf8)

        for (index, failedStep) in BackupFileRotation.Step.allCases.enumerated() {
            let directory = root.appendingPathComponent("case-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let latest = directory.appendingPathComponent("latest")
            let previous = directory.appendingPathComponent("previous")
            try old.write(to: latest)
            try Data("older-previous".utf8).write(to: previous)

            do {
                try BackupFileRotation.rotate(
                    newData: new,
                    latestURL: latest,
                    previousURL: previous,
                    atStep: { step in
                        if step == failedStep { throw InjectedFailure.atBoundary }
                    }
                )
                Issue.record("Expected an injected failure at \(failedStep)")
            } catch InjectedFailure.atBoundary {
                let survivingLatest = try Data(contentsOf: latest)
                #expect(
                    survivingLatest == old || survivingLatest == new,
                    "latest must always contain either the prior or promoted payload"
                )
            }
        }
    }

    @Test func firstBackupCreatesLatestWithoutRequiringPrevious() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let latest = directory.appendingPathComponent("latest")
        let previous = directory.appendingPathComponent("previous")
        let new = Data("first-backup".utf8)

        try BackupFileRotation.rotate(
            newData: new,
            latestURL: latest,
            previousURL: previous
        )

        #expect(try Data(contentsOf: latest) == new)
        #expect(!FileManager.default.fileExists(atPath: previous.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ForgeFit-BackupRotationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
