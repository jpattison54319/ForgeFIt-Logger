import Foundation
import XCTest

struct WatchAcceptanceOracleResult: Codable {
    let id: String
    let outcome: String
    let message: String
}

struct WatchAcceptanceOracle {
    let id: String
    let evaluate: () -> WatchAcceptanceOracleResult
}

struct WatchAcceptanceFailure: Codable {
    let phase: String
    let message: String
    let checkpointID: String?
    let sourceFile: String
    let sourceLine: UInt
}

/// Opt-in, post-action visual evidence for Watch acceptance flows. The Watch
/// target has its own acceptance evidence types, so this recorder keeps the
/// action-level schema self-contained while remaining compatible with the
/// repository's Python judge/report tooling.
final class WatchHumanActionRecorder: NSObject, XCTestObservation {
    static let shared = WatchHumanActionRecorder()

    private struct PendingExpectation {
        let visibleIdentifiers: [String]
        let visibleLabels: [String]
        let phase: String
        let invariants: [String]
        let oracles: [WatchAcceptanceOracle]
    }

    private final class Session {
        let scenarioID: String
        let runID: String
        let rootURL: URL
        weak var app: XCUIApplication?
        var evidence: [WatchActionCheckpointEvidence] = []
        var artifactFiles = Set<String>()
        var nextActionNumber = 1
        var previousScreenshotFile: String?
        var pendingExpectation: PendingExpectation?
        var lastCheckpointID: String?
        var failures: [WatchAcceptanceFailure] = []

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
        AcceptanceRunConfiguration.actionCaptureEnabled
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
        let rootURL = AcceptanceRunConfiguration.artifactRoot
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

    func expect(
        visibleIdentifiers: [String] = [],
        visibleLabels: [String] = [],
        phase: String = "assertion",
        invariants: [String] = [],
        oracles: [WatchAcceptanceOracle] = []
    ) {
        guard isEnabled, let currentScenarioID, let session = sessions[currentScenarioID] else { return }
        session.pendingExpectation = PendingExpectation(
            visibleIdentifiers: visibleIdentifiers,
            visibleLabels: visibleLabels,
            phase: phase,
            invariants: invariants + oracles.map(\.id),
            oracles: oracles
        )
    }

    func recordFailure(
        phase: String,
        message: String,
        sourceFile: StaticString,
        sourceLine: UInt
    ) {
        guard isEnabled, let currentScenarioID, let session = sessions[currentScenarioID] else { return }
        session.failures.append(WatchAcceptanceFailure(
            phase: phase,
            message: message,
            checkpointID: session.lastCheckpointID,
            sourceFile: String(describing: sourceFile),
            sourceLine: sourceLine
        ))
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
        let expectation = session.pendingExpectation ?? PendingExpectation(
            visibleIdentifiers: [],
            visibleLabels: [],
            phase: "assertion",
            invariants: [],
            oracles: []
        )
        session.pendingExpectation = nil
        let checkpointID = String(format: "action-%04d", actionNumber)
        let before = captureState(
            session: session,
            app: session.app ?? app,
            checkpointID: checkpointID,
            phase: "before"
        )

        operation()
        settleForRenderedState(app: session.app ?? app, action: action)

        let after = captureState(
            session: session,
            app: session.app ?? app,
            checkpointID: checkpointID,
            phase: "after"
        )
        var notes = [
            "targetIdentifier=\(targetIdentifier)",
            "targetLabel=\(targetLabel)",
            "targetFrameBefore=\(targetFrame)",
            "source=\(sourceFile):\(sourceLine)",
            "previousScreenshot=\(session.previousScreenshotFile ?? "")",
            "contractDeclared=\(!expectation.visibleIdentifiers.isEmpty || !expectation.visibleLabels.isEmpty || !expectation.invariants.isEmpty)",
            "phase=\(expectation.phase)",
            "invariants=\(expectation.invariants.joined(separator: ","))"
        ]
        notes.append(contentsOf: before.notes.map { "before_\($0)" })
        notes.append(contentsOf: after.notes.map { "after_\($0)" })

        let checkpoint = WatchActionCheckpoint(
            id: checkpointID,
            title: "After \(action): \(targetIdentifier.isEmpty ? targetLabel : targetIdentifier)",
            action: "Perform \(action) on \(targetIdentifier.isEmpty ? targetLabel : targetIdentifier)",
            expectedVisibleIdentifiers: expectation.visibleIdentifiers,
            expectedVisibleLabels: expectation.visibleLabels,
            screenshotRequired: true,
            phase: expectation.phase,
            invariants: expectation.invariants
        )
        let observedIdentifiers = expectation.visibleIdentifiers.filter {
            (session.app ?? app)?.descendants(matching: .any)[$0].firstMatch.exists ?? false
        }
        let observedLabels = expectation.visibleLabels.filter {
            guard let app = session.app ?? app else { return false }
            let predicate = NSPredicate(format: "label == %@", $0)
            return app.descendants(matching: .any).matching(predicate).firstMatch.exists
        }
        let missingIdentifiers = expectation.visibleIdentifiers.filter { !observedIdentifiers.contains($0) }
        let missingLabels = expectation.visibleLabels.filter { !observedLabels.contains($0) }
        let oracleResults = expectation.oracles.map { $0.evaluate() }
        let oracleFailed = oracleResults.contains { $0.outcome != "pass" }
        let contractDeclared = !expectation.visibleIdentifiers.isEmpty
            || !expectation.visibleLabels.isEmpty
            || !expectation.invariants.isEmpty
            || !expectation.oracles.isEmpty
        let artifactsComplete = before.screenshotFile != nil
            && before.accessibilityTreeFile != nil
            && after.screenshotFile != nil
            && after.accessibilityTreeFile != nil
        let outcome: String
        if !artifactsComplete {
            outcome = "blocked"
            notes.append("evidenceIncomplete=true")
        } else if !contractDeclared {
            outcome = "unverified"
        } else if !missingIdentifiers.isEmpty || !missingLabels.isEmpty || oracleFailed {
            outcome = expectation.phase == "setup" ? "blocked" : "fail"
        } else {
            outcome = "pass"
        }
        session.evidence.append(WatchActionCheckpointEvidence(
            scenarioID: session.scenarioID,
            checkpoint: checkpoint,
            outcome: outcome,
            startedAt: startedAt,
            finishedAt: Date(),
            observedIdentifiers: observedIdentifiers,
            observedLabels: observedLabels,
            missingIdentifiers: missingIdentifiers,
            missingLabels: missingLabels,
            screenshotFile: after.screenshotFile,
            accessibilityTreeFile: after.accessibilityTreeFile,
            notes: notes,
            beforeScreenshotFile: before.screenshotFile,
            beforeAccessibilityTreeFile: before.accessibilityTreeFile,
            oracleResults: oracleResults
        ))
        session.lastCheckpointID = checkpointID
    }

    private struct CapturedState {
        let screenshotFile: String?
        let accessibilityTreeFile: String?
        let notes: [String]
    }

    private func captureState(
        session: Session,
        app: XCUIApplication?,
        checkpointID: String,
        phase: String
    ) -> CapturedState {
        let screenshotRelativePath = "screenshots/\(checkpointID)-\(phase).png"
        let treeRelativePath = "accessibility/\(checkpointID)-\(phase).txt"
        var notes: [String] = []
        var screenshotFile: String?
        var accessibilityTreeFile: String?

        do {
            let screenshotURL = session.rootURL.appendingPathComponent(screenshotRelativePath)
            try FileManager.default.createDirectory(
                at: screenshotURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let isRunning = app.map {
                $0.state == .runningForeground || $0.state == .runningBackground
            } ?? false
            let screenshot = isRunning
                ? (app?.screenshot() ?? XCUIScreen.main.screenshot())
                : XCUIScreen.main.screenshot()
            if !isRunning { notes.append("appState=notRunning") }
            try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)
            screenshotFile = screenshotRelativePath
            session.artifactFiles.insert(screenshotRelativePath)
            if phase == "after" { session.previousScreenshotFile = screenshotRelativePath }
        } catch {
            notes.append("screenshotError=\(error.localizedDescription)")
        }

        do {
            let treeURL = session.rootURL.appendingPathComponent(treeRelativePath)
            try FileManager.default.createDirectory(
                at: treeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let isRunning = app.map {
                $0.state == .runningForeground || $0.state == .runningBackground
            } ?? false
            let tree = isRunning
                ? (app?.debugDescription ?? "No registered Watch application tree")
                : "Application not running"
            try tree.write(to: treeURL, atomically: true, encoding: .utf8)
            accessibilityTreeFile = treeRelativePath
            session.artifactFiles.insert(treeRelativePath)
        } catch {
            notes.append("accessibilityTreeError=\(error.localizedDescription)")
        }

        return CapturedState(
            screenshotFile: screenshotFile,
            accessibilityTreeFile: accessibilityTreeFile,
            notes: notes
        )
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard isEnabled else { return }
        guard let currentScenarioID else { return }
        finish(scenarioID: currentScenarioID, succeeded: testCase.testRun?.hasSucceeded ?? true)
    }

    func testCase(
        _ testCase: XCTestCase,
        didFailWithDescription description: String,
        inFile filePath: String?,
        atLine lineNumber: Int
    ) {
        guard isEnabled else { return }
        let session = currentScenarioID.flatMap { sessions[$0] }
        session?.failures.append(WatchAcceptanceFailure(
            phase: "assertion",
            message: description,
            checkpointID: session?.lastCheckpointID,
            sourceFile: filePath ?? "",
            sourceLine: UInt(max(lineNumber, 0))
        ))
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
        let failedCheckpointCount = session.evidence.filter { $0.outcome == "fail" }.count
        let blocked = session.evidence.contains { $0.outcome == "blocked" }
        let unverified = session.evidence.filter { $0.outcome == "unverified" }.count
        let outcome = !succeeded
            ? (blocked ? "blocked" : "fail")
            : (blocked ? "blocked" : (unverified > 0 ? "unverified" : "pass"))
        let manifest = WatchActionManifest(
            schemaVersion: 3,
            runID: session.runID,
            startedAt: session.evidence.first?.startedAt ?? Date(),
            finishedAt: Date(),
            scenario: scenario,
            outcome: outcome,
            checkpointCount: session.evidence.count,
            failedCheckpointCount: failedCheckpointCount,
            artifactFiles: artifactFiles,
            failures: session.failures,
            unverifiedCheckpointCount: unverified,
            rubricID: AcceptanceRunConfiguration.rubricID,
            rubricVersion: AcceptanceRunConfiguration.rubricVersion
        )
        let judgeRequest = WatchActionJudgeRequest(
            schemaVersion: 3,
            scenario: scenario,
            checkpointEvidence: session.evidence,
            judgeInstructions: "Use the checked-in forgefit-ai-acceptance rubric. Review every checkpoint in order, inspect before/after evidence, honor setup versus assertion phases, run the automated tree-lint findings, and report only observable issues. Return one JSON object matching responseSchema.",
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
            ),
            rubricID: AcceptanceRunConfiguration.rubricID,
            rubricVersion: AcceptanceRunConfiguration.rubricVersion,
            failures: session.failures
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

    private func settleForRenderedState(app: XCUIApplication?, action: String) {
        let value = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_SETTLE_SECONDS"]
            .flatMap(TimeInterval.init)
            ?? 0.12
        guard action != "terminate", let app else {
            if value > 0 { Thread.sleep(forTimeInterval: min(value, 1.0)) }
            return
        }
        let idleTimeout = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_IDLE_TIMEOUT"]
            .flatMap(TimeInterval.init)
            ?? 2.0
        guard app.wait(for: .runningForeground, timeout: min(idleTimeout, 5.0)) else {
            if value > 0 { Thread.sleep(forTimeInterval: min(value, 1.0)) }
            return
        }
        let deadline = Date().addingTimeInterval(max(0, idleTimeout))
        var stableSamples = 0
        while Date() < deadline {
            let hasVisibleActivity = app.activityIndicators.allElementsBoundByIndex.contains {
                $0.exists && $0.isHittable
            }
            if hasVisibleActivity {
                stableSamples = 0
            } else {
                stableSamples += 1
                if stableSamples >= 2 { break }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if value > 0 { Thread.sleep(forTimeInterval: min(value, 1.0)) }
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
    let failures: [WatchAcceptanceFailure]
    let unverifiedCheckpointCount: Int
    let rubricID: String
    let rubricVersion: Int

    init(
        schemaVersion: Int,
        runID: String,
        startedAt: Date,
        finishedAt: Date,
        scenario: WatchActionScenario,
        outcome: String,
        checkpointCount: Int,
        failedCheckpointCount: Int,
        artifactFiles: [String],
        failures: [WatchAcceptanceFailure] = [],
        unverifiedCheckpointCount: Int = 0,
        rubricID: String = "forgefit-ai-acceptance",
        rubricVersion: Int = 1
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scenario = scenario
        self.outcome = outcome
        self.checkpointCount = checkpointCount
        self.failedCheckpointCount = failedCheckpointCount
        self.artifactFiles = artifactFiles
        self.failures = failures
        self.unverifiedCheckpointCount = unverifiedCheckpointCount
        self.rubricID = rubricID
        self.rubricVersion = rubricVersion
    }
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
    let phase: String
    let invariants: [String]

    init(
        id: String,
        title: String,
        action: String,
        expectedVisibleIdentifiers: [String],
        expectedVisibleLabels: [String],
        screenshotRequired: Bool,
        phase: String = "assertion",
        invariants: [String] = []
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.expectedVisibleIdentifiers = expectedVisibleIdentifiers
        self.expectedVisibleLabels = expectedVisibleLabels
        self.screenshotRequired = screenshotRequired
        self.phase = phase
        self.invariants = invariants
    }
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
    let beforeScreenshotFile: String?
    let beforeAccessibilityTreeFile: String?
    let oracleResults: [WatchAcceptanceOracleResult]

    init(
        scenarioID: String,
        checkpoint: WatchActionCheckpoint,
        outcome: String,
        startedAt: Date,
        finishedAt: Date,
        observedIdentifiers: [String],
        observedLabels: [String],
        missingIdentifiers: [String],
        missingLabels: [String],
        screenshotFile: String?,
        accessibilityTreeFile: String?,
        notes: [String],
        beforeScreenshotFile: String? = nil,
        beforeAccessibilityTreeFile: String? = nil,
        oracleResults: [WatchAcceptanceOracleResult] = []
    ) {
        self.scenarioID = scenarioID
        self.checkpoint = checkpoint
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.observedIdentifiers = observedIdentifiers
        self.observedLabels = observedLabels
        self.missingIdentifiers = missingIdentifiers
        self.missingLabels = missingLabels
        self.screenshotFile = screenshotFile
        self.accessibilityTreeFile = accessibilityTreeFile
        self.notes = notes
        self.beforeScreenshotFile = beforeScreenshotFile
        self.beforeAccessibilityTreeFile = beforeAccessibilityTreeFile
        self.oracleResults = oracleResults
    }
}

private struct WatchActionJudgeRequest: Codable {
    let schemaVersion: Int
    let scenario: WatchActionScenario
    let checkpointEvidence: [WatchActionCheckpointEvidence]
    let judgeInstructions: String
    let responseSchema: WatchActionResponseSchema
    let rubricID: String
    let rubricVersion: Int
    let failures: [WatchAcceptanceFailure]

    init(
        schemaVersion: Int,
        scenario: WatchActionScenario,
        checkpointEvidence: [WatchActionCheckpointEvidence],
        judgeInstructions: String,
        responseSchema: WatchActionResponseSchema,
        rubricID: String = "forgefit-ai-acceptance",
        rubricVersion: Int = 1,
        failures: [WatchAcceptanceFailure] = []
    ) {
        self.schemaVersion = schemaVersion
        self.scenario = scenario
        self.checkpointEvidence = checkpointEvidence
        self.judgeInstructions = judgeInstructions
        self.responseSchema = responseSchema
        self.rubricID = rubricID
        self.rubricVersion = rubricVersion
        self.failures = failures
    }
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

func watchAcceptanceExpect(
    _ visibleIdentifiers: [String] = [],
    visibleLabels: [String] = [],
    phase: String = "assertion",
    invariants: [String] = [],
    oracles: [WatchAcceptanceOracle] = []
) {
    WatchHumanActionRecorder.shared.expect(
        visibleIdentifiers: visibleIdentifiers,
        visibleLabels: visibleLabels,
        phase: phase,
        invariants: invariants,
        oracles: oracles
    )
}

@discardableResult
func watchAcceptanceRequire(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws -> Bool {
    guard condition() else {
        let text = message()
        WatchHumanActionRecorder.shared.recordFailure(
            phase: "setup",
            message: text,
            sourceFile: file,
            sourceLine: line
        )
        throw XCTSkip("Watch acceptance setup blocked: \(text)")
    }
    return true
}

@discardableResult
func watchAcceptanceAssert(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) -> Bool {
    guard condition() else {
        let text = message()
        WatchHumanActionRecorder.shared.recordFailure(
            phase: "assertion",
            message: text,
            sourceFile: file,
            sourceLine: line
        )
        XCTFail(text, file: file, line: line)
        return false
    }
    return true
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
