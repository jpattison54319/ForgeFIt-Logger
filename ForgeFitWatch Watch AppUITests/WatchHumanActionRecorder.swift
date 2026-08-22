import Foundation
import XCTest

/// Opt-in, post-action visual evidence for Watch acceptance flows. The Watch
/// target has its own acceptance evidence types, so this recorder keeps the
/// action-level schema self-contained while remaining compatible with the
/// repository's Python judge/report tooling.
final class WatchHumanActionRecorder: NSObject, XCTestObservation {
    static let shared = WatchHumanActionRecorder()

    private final class Session {
        let scenarioID: String
        let runID: String
        let rootURL: URL
        weak var app: XCUIApplication?
        var evidence: [WatchActionCheckpointEvidence] = []
        var artifactFiles = Set<String>()
        var nextActionNumber = 1
        var previousScreenshotFile: String?

        init(scenarioID: String, runID: String, rootURL: URL, app: XCUIApplication) {
            self.scenarioID = scenarioID
            self.runID = runID
            self.rootURL = rootURL
            self.app = app
        }
    }

    private var sessions: [String: Session] = [:]
    private var currentScenarioID: String?
    private var observerInstalled = false

    private override init() {
        super.init()
    }

    private var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ACTIONS"] == "1" {
            return true
        }
        let marker = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ACTION_MARKER"]
            ?? "/tmp/forgefit-acceptance/.capture-actions"
        return FileManager.default.fileExists(atPath: marker)
    }

    func register(_ app: XCUIApplication, scenarioID: String) {
        guard isEnabled else { return }
        installObserverIfNeeded()
        if let existing = sessions[scenarioID] {
            existing.app = app
            currentScenarioID = scenarioID
            return
        }

        let runID = UUID().uuidString.lowercased()
        let basePath = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ARTIFACTS"]
            ?? "/tmp/forgefit-acceptance"
        let rootURL = URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent("action-evidence", isDirectory: true)
            .appendingPathComponent(safePathComponent(scenarioID), isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            sessions[scenarioID] = Session(
                scenarioID: scenarioID,
                runID: runID,
                rootURL: rootURL,
                app: app
            )
            currentScenarioID = scenarioID
        } catch {
            XCTFail("Could not create Watch action evidence directory: \(error.localizedDescription)")
        }
    }

    func perform(
        action: String,
        target: XCUIElement? = nil,
        app: XCUIApplication? = nil,
        sourceFile: StaticString,
        sourceLine: UInt,
        operation: () -> Void
    ) {
        guard isEnabled else {
            operation()
            return
        }
        if let app {
            sessions[currentScenarioID ?? ""]?.app = app
        }
        guard let currentScenarioID, let session = sessions[currentScenarioID] else {
            operation()
            return
        }

        let startedAt = Date()
        let actionNumber = session.nextActionNumber
        session.nextActionNumber += 1
        let targetIdentifier = target?.identifier ?? ""
        let targetLabel = target?.label ?? ""
        let targetFrame = target.map { String(describing: $0.frame) } ?? ""

        operation()
        settleForRenderedState()

        let checkpointID = String(format: "action-%04d", actionNumber)
        let screenshotRelativePath = "screenshots/\(checkpointID)-after.png"
        let treeRelativePath = "accessibility/\(checkpointID)-after.txt"
        var notes = [
            "targetIdentifier=\(targetIdentifier)",
            "targetLabel=\(targetLabel)",
            "targetFrameBefore=\(targetFrame)",
            "source=\(sourceFile):\(sourceLine)",
            "previousScreenshot=\(session.previousScreenshotFile ?? "")"
        ]
        var screenshotFile: String?
        var accessibilityTreeFile: String?

        do {
            let screenshotURL = session.rootURL.appendingPathComponent(screenshotRelativePath)
            try FileManager.default.createDirectory(
                at: screenshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let screenshot = session.app?.screenshot() ?? XCUIScreen.main.screenshot()
            try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
            screenshotFile = screenshotRelativePath
            session.artifactFiles.insert(screenshotRelativePath)
            session.previousScreenshotFile = screenshotRelativePath
        } catch {
            notes.append("screenshotError=\(error.localizedDescription)")
        }

        do {
            let treeURL = session.rootURL.appendingPathComponent(treeRelativePath)
            try FileManager.default.createDirectory(
                at: treeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let tree = session.app?.debugDescription ?? "No registered Watch application tree"
            try tree.write(to: treeURL, atomically: true, encoding: .utf8)
            accessibilityTreeFile = treeRelativePath
            session.artifactFiles.insert(treeRelativePath)
        } catch {
            notes.append("accessibilityTreeError=\(error.localizedDescription)")
        }

        let checkpoint = WatchActionCheckpoint(
            id: checkpointID,
            title: "After \(action): \(targetIdentifier.isEmpty ? targetLabel : targetIdentifier)",
            action: "Perform \(action) on \(targetIdentifier.isEmpty ? targetLabel : targetIdentifier)",
            expectedVisibleIdentifiers: [],
            expectedVisibleLabels: [],
            screenshotRequired: true
        )
        session.evidence.append(WatchActionCheckpointEvidence(
            scenarioID: session.scenarioID,
            checkpoint: checkpoint,
            outcome: "pass",
            startedAt: startedAt,
            finishedAt: Date(),
            observedIdentifiers: [],
            observedLabels: [],
            missingIdentifiers: [],
            missingLabels: [],
            screenshotFile: screenshotFile,
            accessibilityTreeFile: accessibilityTreeFile,
            notes: notes
        ))
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard isEnabled else { return }
        guard let currentScenarioID else { return }
        finish(scenarioID: currentScenarioID, succeeded: testCase.testRun?.hasSucceeded ?? true)
    }

    private func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    private func finish(scenarioID: String, succeeded: Bool) {
        guard let session = sessions.removeValue(forKey: scenarioID) else { return }
        currentScenarioID = nil

        let scenario = WatchActionScenario(
            id: session.scenarioID,
            title: "Human-like Watch replay: \(session.scenarioID)",
            purpose: "Inspect the rendered Watch result after every deterministic user action.",
            fixtureArguments: [],
            checkpoints: session.evidence.map(\.checkpoint)
        )
        let artifactFiles = Array(session.artifactFiles).sorted() + ["manifest.json", "judge-request.json"]
        let manifest = WatchActionManifest(
            schemaVersion: 2,
            runID: session.runID,
            startedAt: session.evidence.first?.startedAt ?? Date(),
            finishedAt: Date(),
            scenario: scenario,
            outcome: succeeded ? "pass" : "fail",
            checkpointCount: session.evidence.count,
            failedCheckpointCount: succeeded ? 0 : 1,
            artifactFiles: artifactFiles
        )
        let judgeRequest = WatchActionJudgeRequest(
            schemaVersion: 2,
            scenario: scenario,
            checkpointEvidence: session.evidence,
            judgeInstructions: "Each checkpoint is the rendered Watch screen immediately after one user-like action. Inspect every checkpoint screenshot and accessibility tree in sequence. Do not sample. Look for visual defects, clipping, duplicated rows, stale labels, missing affordances, failed transitions, touch-target concerns, loading/error states, and anything a human user would find confusing or suspicious. Report the first divergent checkpoint and use an empty findings array only when the complete sequence is clean.",
            responseSchema: WatchActionResponseSchema(
                outcome: "pass | fail | suspect | blocked",
                findings: [WatchActionFinding(
                    severity: "blocker | critical | major | minor | polish",
                    category: "functionality | visual | accessibility | copy | interaction | persistence | performance | privacy | watch-sync | reliability",
                    observation: "What was observed",
                    expected: "What the action and product convention require",
                    actual: "What the rendered evidence shows",
                    confidence: 0.0,
                    checkpointID: "action checkpoint id",
                    evidencePaths: ["relative/path/to/evidence"]
                )]
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try encoder.encode(manifest).write(
                to: session.rootURL.appendingPathComponent("manifest.json"),
                options: .atomic
            )
            try encoder.encode(judgeRequest).write(
                to: session.rootURL.appendingPathComponent("judge-request.json"),
                options: .atomic
            )
        } catch {
            XCTFail("Could not write Watch action manifest: \(error.localizedDescription)")
        }
    }

    private func settleForRenderedState() {
        let value = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_SETTLE_SECONDS"]
            .flatMap(TimeInterval.init)
            ?? 0.12
        guard value > 0 else { return }
        Thread.sleep(forTimeInterval: min(value, 1.0))
    }

    private func safePathComponent(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            let isSafeASCII = scalar.isASCII && (
                scalar.properties.isAlphabetic
                    || (code >= 48 && code <= 57)
                    || code == 45
                    || code == 46
                    || code == 47
                    || code == 95
                    || code == 32
            )
            return isSafeASCII ? String(scalar) : "-"
        }
        .joined()
        .replacingOccurrences(of: "/", with: "--")
        .replacingOccurrences(of: " ", with: "-")
    }
}

private struct WatchActionManifest: Codable {
    let schemaVersion: Int
    let runID: String
    let startedAt: Date
    let finishedAt: Date
    let scenario: WatchActionScenario
    let outcome: String
    let checkpointCount: Int
    let failedCheckpointCount: Int
    let artifactFiles: [String]
}

private struct WatchActionScenario: Codable {
    let id: String
    let title: String
    let purpose: String
    let fixtureArguments: [String]
    let checkpoints: [WatchActionCheckpoint]
}

private struct WatchActionCheckpoint: Codable {
    let id: String
    let title: String
    let action: String
    let expectedVisibleIdentifiers: [String]
    let expectedVisibleLabels: [String]
    let screenshotRequired: Bool
}

private struct WatchActionCheckpointEvidence: Codable {
    let scenarioID: String
    let checkpoint: WatchActionCheckpoint
    let outcome: String
    let startedAt: Date
    let finishedAt: Date
    let observedIdentifiers: [String]
    let observedLabels: [String]
    let missingIdentifiers: [String]
    let missingLabels: [String]
    let screenshotFile: String?
    let accessibilityTreeFile: String?
    let notes: [String]
}

private struct WatchActionJudgeRequest: Codable {
    let schemaVersion: Int
    let scenario: WatchActionScenario
    let checkpointEvidence: [WatchActionCheckpointEvidence]
    let judgeInstructions: String
    let responseSchema: WatchActionResponseSchema
}

private struct WatchActionResponseSchema: Codable {
    let outcome: String
    let findings: [WatchActionFinding]
}

private struct WatchActionFinding: Codable {
    let severity: String
    let category: String
    let observation: String
    let expected: String
    let actual: String
    let confidence: Double
    let checkpointID: String
    let evidencePaths: [String]
}

extension XCUIElement {
    func watchAcceptanceTap(file: StaticString = #fileID, line: UInt = #line) {
        WatchHumanActionRecorder.shared.perform(
            action: "tap",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.tap()
        }
    }

    func watchAcceptanceSwipeUp(file: StaticString = #fileID, line: UInt = #line) {
        WatchHumanActionRecorder.shared.perform(
            action: "swipeUp",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.swipeUp()
        }
    }

    func watchAcceptancePress(
        forDuration duration: TimeInterval,
        thenDragTo otherElement: XCUIElement,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        WatchHumanActionRecorder.shared.perform(
            action: "pressAndDrag",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(forDuration: duration, thenDragTo: otherElement)
        }
    }
}

extension XCUICoordinate {
    func watchAcceptancePress(
        forDuration duration: TimeInterval,
        thenDragTo otherCoordinate: XCUICoordinate,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        WatchHumanActionRecorder.shared.perform(
            action: "coordinatePressAndDrag",
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(forDuration: duration, thenDragTo: otherCoordinate)
        }
    }
}

extension XCUIApplication {
    func watchAcceptanceLaunch(file: StaticString = #fileID, line: UInt = #line) {
        WatchHumanActionRecorder.shared.perform(
            action: "launch",
            app: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.launch()
        }
    }
}
