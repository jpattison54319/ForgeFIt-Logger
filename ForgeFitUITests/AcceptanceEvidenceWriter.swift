import Foundation
import UIKit
import XCTest

@MainActor
final class AcceptanceEvidenceWriter {
    let scenarioID: String
    let runID: String
    let rootURL: URL
    private(set) var evidence: [AcceptanceCheckpointEvidence] = []
    private var artifactFiles: [String] = []

    init(scenarioID: String) throws {
        self.scenarioID = scenarioID
        runID = UUID().uuidString.lowercased()
        let basePath = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ARTIFACTS"]
            ?? "/tmp/forgefit-acceptance"
        rootURL = URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent(scenarioID, isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func record(
        checkpoint: AcceptanceCheckpoint,
        app: XCUIApplication,
        outcome: AcceptanceOutcome,
        startedAt: Date,
        notes: [String] = []
    ) throws {
        let observedIdentifiers = checkpoint.expectedVisibleIdentifiers.filter {
            app.descendants(matching: .any)[$0].firstMatch.exists
        }
        let observedLabels = checkpoint.expectedVisibleLabels.filter {
            app.staticTexts[$0].firstMatch.exists || app.buttons[$0].firstMatch.exists
        }
        let missingIdentifiers = checkpoint.expectedVisibleIdentifiers.filter {
            !observedIdentifiers.contains($0)
        }
        let missingLabels = checkpoint.expectedVisibleLabels.filter {
            !observedLabels.contains($0)
        }

        var screenshotFile: String?
        if checkpoint.screenshotRequired {
            let name = "screenshots/\(checkpoint.id).png"
            let url = rootURL.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let screenshot = app.screenshot()
            XCTContext.runActivity(named: "Capture \(checkpoint.title)") { activity in
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = checkpoint.id
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            try screenshot.pngRepresentation.write(to: url, options: .atomic)
            screenshotFile = name
            artifactFiles.append(name)
        }

        let treeName = "accessibility/\(checkpoint.id).txt"
        let treeURL = rootURL.appendingPathComponent(treeName)
        try FileManager.default.createDirectory(at: treeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try app.debugDescription.write(to: treeURL, atomically: true, encoding: .utf8)
        artifactFiles.append(treeName)

        evidence.append(AcceptanceCheckpointEvidence(
            scenarioID: scenarioID,
            checkpoint: checkpoint,
            outcome: outcome,
            startedAt: startedAt,
            finishedAt: .now,
            observedIdentifiers: observedIdentifiers,
            observedLabels: observedLabels,
            missingIdentifiers: missingIdentifiers,
            missingLabels: missingLabels,
            screenshotFile: screenshotFile,
            accessibilityTreeFile: treeName,
            notes: notes
        ))
    }

    func finish(scenario: AcceptanceScenario, startedAt: Date, environment: AcceptanceEnvironment) throws {
        let failed = evidence.filter { $0.outcome == .fail || !$0.missingIdentifiers.isEmpty || !$0.missingLabels.isEmpty }.count
        let outcome: AcceptanceOutcome = failed == 0 ? .pass : .fail
        let manifest = AcceptanceRunManifest(
            schemaVersion: 1,
            runID: runID,
            startedAt: startedAt,
            finishedAt: .now,
            scenario: scenario,
            environment: environment,
            outcome: outcome,
            checkpointCount: evidence.count,
            failedCheckpointCount: failed,
            artifactFiles: artifactFiles + ["manifest.json", "judge-request.json"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: rootURL.appendingPathComponent("manifest.json"), options: .atomic)

        let judgeRequest = AcceptanceJudgeRequest(
            schemaVersion: 1,
            scenario: scenario,
            checkpointEvidence: evidence,
            judgeInstructions: "Review every screenshot and accessibility tree. Report only observable issues. Distinguish confirmed failures from suspects. Check functionality, visual hierarchy, copy, affordances, accessibility, and consistency with the checkpoint contract. Return one JSON object matching responseSchema. Use an empty findings array when no issue is observed.",
            responseSchema: AcceptanceJudgeResponseSchema(
                outcome: "pass | fail | suspect | blocked",
                findings: [AcceptanceJudgeFinding(
                    severity: "blocker | critical | major | minor | polish",
                    category: "functionality | visual | accessibility | copy | interaction | persistence | performance | privacy | watch-sync | reliability",
                    observation: "What was observed",
                    expected: "What the contract or platform convention requires",
                    actual: "What the evidence shows",
                    confidence: 0.0,
                    checkpointID: "checkpoint id",
                    evidencePaths: ["relative/path/to/evidence"]
                )]
            )
        )
        try encoder.encode(judgeRequest).write(to: rootURL.appendingPathComponent("judge-request.json"), options: .atomic)
    }

    private func environment() -> AcceptanceEnvironment {
        AcceptanceEnvironment(
            platform: "iOS Simulator",
            device: UIDevice.current.name,
            operatingSystem: UIDevice.current.systemVersion,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            appearance: "system",
            dynamicType: "default",
            gitCommit: ProcessInfo.processInfo.environment["GIT_COMMIT"]
        )
    }

    func finish(scenario: AcceptanceScenario, startedAt: Date) throws {
        try finish(scenario: scenario, startedAt: startedAt, environment: environment())
    }
}
