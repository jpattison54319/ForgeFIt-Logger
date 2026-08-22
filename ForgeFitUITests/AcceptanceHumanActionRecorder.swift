import Foundation
import XCTest

/// Captures the visible result of each user-like UI action during an acceptance
/// run. The recorder is deliberately opt-in through a temporary marker file so
/// ordinary focused UI tests do not pay the screenshot and accessibility-tree
/// cost.
final class AcceptanceHumanActionRecorder: NSObject, XCTestObservation {
    static let shared = AcceptanceHumanActionRecorder()

    private final class Session {
        let scenarioID: String
        let runID: String
        let rootURL: URL
        weak var app: XCUIApplication?
        var evidence: [AcceptanceCheckpointEvidence] = []
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

    /// Register the app instance used by the current XCTest flow. `testName`
    /// is XCTestCase.name (for example, `-[Module.Class testFlow]`) when the
    /// call is made from a test method; the source file is the fallback for
    /// helper-created application instances.
    func register(_ app: XCUIApplication, testName: String, sourceFile: String) {
        guard isEnabled else { return }
        installObserverIfNeeded()

        let scenarioID = normalizeTestIdentifier(testName, sourceFile: sourceFile)
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
            XCTFail("Could not create human-like acceptance evidence directory: \(error.localizedDescription)")
        }
    }

    /// Associate an inline `XCUIApplication()` action with the current flow.
    func attach(_ app: XCUIApplication) {
        guard isEnabled, let currentScenarioID, let session = sessions[currentScenarioID] else { return }
        session.app = app
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
            attach(app)
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
        let title = "After \(action): \(targetIdentifier.isEmpty ? targetLabel : targetIdentifier)"
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
            // Asking a terminated application for a screenshot raises its own
            // test failure, which turned every relaunch flow ("terminate, then
            // verify from a cold store") into a harness failure at the exact
            // point the evidence mattered. The screen still has something worth
            // recording after a terminate, so fall back to it.
            let target = session.app ?? app
            let isRunning = target.map {
                $0.state == .runningForeground || $0.state == .runningBackground
            } ?? false
            let screenshot = isRunning
                ? (target?.screenshot() ?? XCUIScreen.main.screenshot())
                : XCUIScreen.main.screenshot()
            if !isRunning { notes.append("appState=notRunning") }
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
            let treeSource = session.app ?? app
            let treeIsAvailable = treeSource.map {
                $0.state == .runningForeground || $0.state == .runningBackground
            } ?? false
            let tree = treeIsAvailable
                ? (treeSource?.debugDescription ?? "No registered application tree")
                : "Application not running"
            try tree.write(to: treeURL, atomically: true, encoding: .utf8)
            accessibilityTreeFile = treeRelativePath
            session.artifactFiles.insert(treeRelativePath)
        } catch {
            notes.append("accessibilityTreeError=\(error.localizedDescription)")
        }

        let checkpoint = AcceptanceCheckpoint(
            id: checkpointID,
            title: title,
            action: "Perform \(action) on \(targetIdentifier.isEmpty ? targetLabel : targetIdentifier)",
            expectedVisibleIdentifiers: [],
            expectedVisibleLabels: [],
            screenshotRequired: true
        )
        session.evidence.append(AcceptanceCheckpointEvidence(
            scenarioID: session.scenarioID,
            checkpoint: checkpoint,
            outcome: .pass,
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
        let testIdentifier = normalizeTestIdentifier(testCase.name, sourceFile: "")
        if sessions[testIdentifier] != nil {
            finish(testIdentifier: testIdentifier, succeeded: testCase.testRun?.hasSucceeded ?? true)
        } else if sessions.count == 1, let onlyIdentifier = sessions.keys.first {
            // XCTest's name formatting differs between Xcode releases. The
            // single-session fallback keeps artifacts attached to the flow.
            finish(testIdentifier: onlyIdentifier, succeeded: testCase.testRun?.hasSucceeded ?? true)
        }
    }

    private func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    private func finish(testIdentifier: String, succeeded: Bool) {
        guard let session = sessions.removeValue(forKey: testIdentifier) else { return }
        if currentScenarioID == testIdentifier {
            currentScenarioID = nil
        }

        let scenario = AcceptanceScenario(
            id: session.scenarioID,
            title: "Human-like replay: \(session.scenarioID)",
            purpose: "Inspect the rendered result after every deterministic user action.",
            fixtureArguments: [],
            checkpoints: session.evidence.map(\.checkpoint)
        )
        let artifactFiles = Array(session.artifactFiles).sorted() + ["manifest.json", "judge-request.json"]
        let manifest = AcceptanceRunManifest(
            schemaVersion: 2,
            runID: session.runID,
            startedAt: session.evidence.first?.startedAt ?? Date(),
            finishedAt: Date(),
            scenario: scenario,
            environment: AcceptanceEnvironment(
                platform: "iOS Simulator",
                device: "unknown",
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                locale: Locale.current.identifier,
                timeZone: TimeZone.current.identifier,
                appearance: "system",
                dynamicType: "default",
                gitCommit: ProcessInfo.processInfo.environment["GIT_COMMIT"]
            ),
            outcome: succeeded ? .pass : .fail,
            checkpointCount: session.evidence.count,
            failedCheckpointCount: succeeded ? 0 : 1,
            artifactFiles: artifactFiles
        )

        let judgeRequest = AcceptanceJudgeRequest(
            schemaVersion: 2,
            scenario: scenario,
            checkpointEvidence: session.evidence,
            judgeInstructions: "Each checkpoint is the rendered screen immediately after one user-like action. Inspect every checkpoint screenshot and accessibility tree in sequence. Do not review only a representative subset. Compare the resulting state with the action and look for visual defects, clipping, duplicated rows, stale labels, missing affordances, failed transitions, touch-target concerns, loading/error states, and anything a human user would find confusing or suspicious. Report the first divergent checkpoint and use an empty findings array only when the complete sequence is clean.",
            responseSchema: AcceptanceJudgeResponseSchema(
                outcome: "pass | fail | suspect | blocked",
                findings: [AcceptanceJudgeFinding(
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
            XCTFail("Could not write human-like acceptance manifest for \(testIdentifier): \(error.localizedDescription)")
        }
    }

    private func settleForRenderedState() {
        let value = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_SETTLE_SECONDS"]
            .flatMap(TimeInterval.init)
            ?? 0.12
        guard value > 0 else { return }
        Thread.sleep(forTimeInterval: min(value, 1.0))
    }

    private func normalizeTestIdentifier(_ testName: String, sourceFile: String) -> String {
        if let openBracket = testName.firstIndex(of: "["),
           let closeBracket = testName.firstIndex(of: "]"),
           openBracket < closeBracket {
            let body = testName[testName.index(after: openBracket)..<closeBracket]
            let parts = body.split(separator: " ")
            if parts.count >= 2 {
                let className = parts[0].split(separator: ".").last.map(String.init) ?? String(parts[0])
                return "\(className)/\(parts[1])"
            }
        }

        let fileName = URL(fileURLWithPath: sourceFile).deletingPathExtension().lastPathComponent
        let method = testName.isEmpty ? "unknown" : testName
        return "\(fileName.isEmpty ? "AcceptanceFlow" : fileName)/\(method)"
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

private let acceptanceHumanActionRecorder = AcceptanceHumanActionRecorder.shared

extension XCUIElement {
    func acceptanceTap(file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "tap",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.tap()
        }
    }

    func acceptanceSwipeUp(file: StaticString = #fileID, line: UInt = #line) {
        acceptanceSwipeUp(velocity: nil, file: file, line: line)
    }

    func acceptanceSwipeUp(velocity: XCUIGestureVelocity, file: StaticString = #fileID, line: UInt = #line) {
        acceptanceSwipeUp(velocity: Optional(velocity), file: file, line: line)
    }

    private func acceptanceSwipeUp(velocity: XCUIGestureVelocity?, file: StaticString, line: UInt) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: velocity == nil ? "swipeUp" : "swipeUp(\(velocity!))",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            if let velocity {
                self.swipeUp(velocity: velocity)
            } else {
                self.swipeUp()
            }
        }
    }

    func acceptanceSwipeDown(velocity: XCUIGestureVelocity? = nil, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: velocity == nil ? "swipeDown" : "swipeDown(\(velocity!))",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            if let velocity {
                self.swipeDown(velocity: velocity)
            } else {
                self.swipeDown()
            }
        }
    }

    func acceptanceSwipeLeft(velocity: XCUIGestureVelocity? = nil, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: velocity == nil ? "swipeLeft" : "swipeLeft(\(velocity!))",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            if let velocity {
                self.swipeLeft(velocity: velocity)
            } else {
                self.swipeLeft()
            }
        }
    }

    func acceptanceSwipeRight(velocity: XCUIGestureVelocity? = nil, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: velocity == nil ? "swipeRight" : "swipeRight(\(velocity!))",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            if let velocity {
                self.swipeRight(velocity: velocity)
            } else {
                self.swipeRight()
            }
        }
    }

    func acceptanceTypeText(_ text: String, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "typeText",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.typeText(text)
        }
    }

    func acceptancePress(forDuration duration: TimeInterval, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "press",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(forDuration: duration)
        }
    }

    func acceptancePress(forDuration duration: TimeInterval, thenDragTo otherElement: XCUIElement, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
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
    func acceptanceTap(file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "coordinateTap",
            sourceFile: file,
            sourceLine: line
        ) {
            self.tap()
        }
    }

    func acceptancePress(forDuration duration: TimeInterval, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "coordinatePress",
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(forDuration: duration)
        }
    }

    func acceptancePress(forDuration duration: TimeInterval, thenDragTo otherCoordinate: XCUICoordinate, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "coordinatePressAndDrag",
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(forDuration: duration, thenDragTo: otherCoordinate)
        }
    }

    func acceptancePress(
        forDuration duration: TimeInterval,
        thenDragTo otherCoordinate: XCUICoordinate,
        withVelocity velocity: XCUIGestureVelocity,
        thenHoldForDuration holdDuration: TimeInterval,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "coordinatePressAndDrag(\(velocity))",
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(
                forDuration: duration,
                thenDragTo: otherCoordinate,
                withVelocity: velocity,
                thenHoldForDuration: holdDuration
            )
        }
    }
}

extension XCUIApplication {
    func acceptanceLaunch(file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.attach(self)
        AcceptanceHumanActionRecorder.shared.perform(
            action: "launch",
            app: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.launch()
        }
    }

    func acceptanceTerminate(file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "terminate",
            app: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.terminate()
        }
    }

    func acceptanceActivate(file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "activate",
            app: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.activate()
        }
    }
}

extension XCUIDevice {
    func acceptancePress(_ button: XCUIDevice.Button, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "devicePress",
            sourceFile: file,
            sourceLine: line
        ) {
            self.press(button)
        }
    }
}
