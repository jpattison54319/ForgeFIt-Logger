import Foundation
import XCTest

/// Captures the visible result of each user-like UI action during an acceptance
/// run. The recorder is deliberately opt-in through a temporary marker file so
/// ordinary focused UI tests do not pay the screenshot and accessibility-tree
/// cost.
final class AcceptanceHumanActionRecorder: NSObject, XCTestObservation {
    static let shared = AcceptanceHumanActionRecorder()

    private struct PendingExpectation {
        let visibleIdentifiers: [String]
        let visibleLabels: [String]
        let phase: AcceptanceCheckpointPhase
        let invariants: [String]
        let oracles: [AcceptanceOracle]
        let sourceFile: String
        let sourceLine: UInt
    }

    private final class Session {
        let scenarioID: String
        let runID: String
        let rootURL: URL
        weak var app: XCUIApplication?
        var evidence: [AcceptanceCheckpointEvidence] = []
        var artifactFiles = Set<String>()
        var nextActionNumber = 1
        var previousScreenshotFile: String?
        var pendingExpectation: PendingExpectation?
        var failures: [AcceptanceFailureEvidence] = []
        var lastCheckpointID: String?

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
            XCTFail("Could not create human-like acceptance evidence directory: \(error.localizedDescription)")
        }
    }

    /// Associate an inline `XCUIApplication()` action with the current flow.
    func attach(_ app: XCUIApplication) {
        guard isEnabled, let currentScenarioID, let session = sessions[currentScenarioID] else { return }
        session.app = app
    }

    /// Declare the contract that the next wrapped action must satisfy. Keeping
    /// this separate from the gesture makes the expected post-action state
    /// explicit without hiding it inside a helper implementation.
    func expect(
        visibleIdentifiers: [String] = [],
        visibleLabels: [String] = [],
        phase: AcceptanceCheckpointPhase = .assertion,
        invariants: [String] = [],
        oracles: [AcceptanceOracle] = [],
        sourceFile: StaticString = #fileID,
        sourceLine: UInt = #line
    ) {
        guard isEnabled, let currentScenarioID, let session = sessions[currentScenarioID] else { return }
        if let pending = session.pendingExpectation {
            session.failures.append(AcceptanceFailureEvidence(
                phase: pending.phase,
                message: "declaredButUnused: expectation was replaced before a wrapped action ran",
                checkpointID: nil,
                sourceFile: pending.sourceFile,
                sourceLine: pending.sourceLine
            ))
        }
        session.pendingExpectation = PendingExpectation(
            visibleIdentifiers: visibleIdentifiers,
            visibleLabels: visibleLabels,
            phase: phase,
            invariants: invariants + oracles.map(\.id),
            oracles: oracles,
            sourceFile: String(describing: sourceFile),
            sourceLine: sourceLine
        )
    }

    func recordFailure(
        phase: AcceptanceCheckpointPhase,
        message: String,
        sourceFile: StaticString,
        sourceLine: UInt
    ) {
        guard isEnabled, let currentScenarioID, let session = sessions[currentScenarioID] else { return }
        session.failures.append(AcceptanceFailureEvidence(
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
        let expectation = session.pendingExpectation ?? PendingExpectation(
            visibleIdentifiers: [],
            visibleLabels: [],
            phase: .assertion,
            invariants: [],
            oracles: [],
            sourceFile: "<implicit>",
            sourceLine: 0
        )
        session.pendingExpectation = nil
        let checkpointID = String(format: "action-%04d", actionNumber)
        let targetApplication = session.app ?? app
        // Querying XCUIApplication.state before launch freezes the launch
        // configuration on Xcode 27, dropping launchArguments from the app
        // process. A launch begins from a known not-running contract, so keep
        // the required before artifacts without touching the application proxy.
        let before = captureState(
            session: session,
            app: action == "launch" ? nil : targetApplication,
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
            "contractDeclared=\(!expectation.visibleIdentifiers.isEmpty || !expectation.visibleLabels.isEmpty || !expectation.invariants.isEmpty || !expectation.oracles.isEmpty)",
            "phase=\(expectation.phase.rawValue)",
            "invariants=\(expectation.invariants.joined(separator: ","))"
        ]
        notes.append(contentsOf: before.notes.map { "before_\($0)" })
        notes.append(contentsOf: after.notes.map { "after_\($0)" })

        let checkpoint = AcceptanceCheckpoint(
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
        let missingIdentifiers = expectation.visibleIdentifiers.filter {
            !observedIdentifiers.contains($0)
        }
        let missingLabels = expectation.visibleLabels.filter {
            !observedLabels.contains($0)
        }
        let oracleResults = expectation.oracles.map { $0.evaluate() }
        let oracleFailed = oracleResults.contains { $0.outcome != .pass }
        let contractDeclared = !expectation.visibleIdentifiers.isEmpty
            || !expectation.visibleLabels.isEmpty
            || !expectation.invariants.isEmpty
            || !expectation.oracles.isEmpty
        let artifactsComplete = before.screenshotFile != nil
            && before.accessibilityTreeFile != nil
            && after.screenshotFile != nil
            && after.accessibilityTreeFile != nil
        let outcome: AcceptanceOutcome
        if !artifactsComplete {
            outcome = .blocked
            notes.append("evidenceIncomplete=true")
        } else if !contractDeclared {
            outcome = .unverified
        } else if !missingIdentifiers.isEmpty || !missingLabels.isEmpty || oracleFailed {
            outcome = expectation.phase == .setup ? .blocked : .fail
        } else {
            outcome = .pass
        }

        session.evidence.append(AcceptanceCheckpointEvidence(
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
        if outcome == .fail {
            let missing = (missingIdentifiers + missingLabels).joined(separator: ", ")
            let oracleMessages = oracleResults
                .filter { $0.outcome != .pass }
                .map { "\($0.id): \($0.message)" }
                .joined(separator: "; ")
            let details = [missing.isEmpty ? nil : "missing=\(missing)", oracleMessages.isEmpty ? nil : oracleMessages]
                .compactMap { $0 }
                .joined(separator: "; ")
            XCTFail(
                "Acceptance contract failed at \(checkpointID)\(details.isEmpty ? "" : ": \(details)")",
                file: sourceFile,
                line: sourceLine
            )
        }
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
            if phase == "after" {
                session.previousScreenshotFile = screenshotRelativePath
            }
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
            var tree = isRunning
                ? (app?.debugDescription ?? "No registered application tree")
                : "Application not running"
            if isRunning, let app {
                let stateLines = acceptanceElementStateLines(app: app, tree: tree)
                tree += "\n\n--- ForgeFit acceptance element state (JSONL) ---\n\(stateLines)\n"
            }
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

    private struct AcceptanceElementTypeQuery {
        let elementType: XCUIElement.ElementType
        let debugName: String
    }

    private struct AcceptanceStateCandidate {
        let query: AcceptanceElementTypeQuery
        let identifier: String
        let label: String
        let frame: CGRect
    }

    private struct AcceptanceCandidateQueryKey: Hashable {
        let typeName: String
        let identifier: String
        let label: String
    }

    private func acceptanceElementStateLines(app: XCUIApplication, tree: String) -> String {
        let startedAt = Date.now
        let interactiveTypes = [
            AcceptanceElementTypeQuery(elementType: .button, debugName: "Button"),
            AcceptanceElementTypeQuery(elementType: .cell, debugName: "Cell"),
            AcceptanceElementTypeQuery(elementType: .collectionView, debugName: "CollectionView"),
            AcceptanceElementTypeQuery(elementType: .datePicker, debugName: "DatePicker"),
            AcceptanceElementTypeQuery(elementType: .link, debugName: "Link"),
            AcceptanceElementTypeQuery(elementType: .menuItem, debugName: "MenuItem"),
            AcceptanceElementTypeQuery(elementType: .picker, debugName: "Picker"),
            AcceptanceElementTypeQuery(elementType: .searchField, debugName: "SearchField"),
            AcceptanceElementTypeQuery(elementType: .segmentedControl, debugName: "SegmentedControl"),
            AcceptanceElementTypeQuery(elementType: .slider, debugName: "Slider"),
            AcceptanceElementTypeQuery(elementType: .stepper, debugName: "Stepper"),
            AcceptanceElementTypeQuery(elementType: .switch, debugName: "Switch"),
            AcceptanceElementTypeQuery(elementType: .secureTextField, debugName: "SecureTextField"),
            AcceptanceElementTypeQuery(elementType: .textField, debugName: "TextField"),
            AcceptanceElementTypeQuery(elementType: .textView, debugName: "TextView"),
            AcceptanceElementTypeQuery(elementType: .toggle, debugName: "Toggle")
        ]
        let candidates = acceptanceStateCandidates(in: tree, interactiveTypes: interactiveTypes)
        var records: [String] = []
        var serializationErrorCount = 0
        var geometricNonHittableCount = 0
        var conservativeRecordCount = 0
        var queryCount = 0
        var queriedTypes = Set<String>()
        let applicationFrame = app.frame

        var groupedCandidates: [AcceptanceCandidateQueryKey: [AcceptanceStateCandidate]] = [:]
        for candidate in candidates {
            guard acceptanceFrameIsInViewport(candidate.frame, viewport: applicationFrame) else {
                geometricNonHittableCount += 1
                acceptanceAppendStateRecord(
                    candidate: candidate,
                    hittable: false,
                    enabled: true,
                    source: "outsideViewport",
                    records: &records,
                    serializationErrorCount: &serializationErrorCount
                )
                continue
            }
            guard !candidate.identifier.isEmpty || !candidate.label.isEmpty else {
                conservativeRecordCount += 1
                acceptanceAppendStateRecord(
                    candidate: candidate,
                    hittable: true,
                    enabled: true,
                    source: "conservativeAnonymous",
                    records: &records,
                    serializationErrorCount: &serializationErrorCount
                )
                continue
            }
            let key = AcceptanceCandidateQueryKey(
                typeName: candidate.query.debugName,
                identifier: candidate.identifier,
                label: candidate.identifier.isEmpty ? candidate.label : ""
            )
            groupedCandidates[key, default: []].append(candidate)
        }

        for (key, group) in groupedCandidates {
            guard let first = group.first else { continue }
            queryCount += 1
            queriedTypes.insert(first.query.debugName)
            let baseQuery = app.descendants(matching: first.query.elementType)
            let targetedQuery = key.identifier.isEmpty
                ? baseQuery.matching(NSPredicate(format: "label == %@", key.label))
                : baseQuery.matching(NSPredicate(format: "identifier == %@", key.identifier))
            var unresolved = group
            for element in targetedQuery.allElementsBoundByIndex {
                let resolvedFrame = element.frame
                guard let index = unresolved.firstIndex(where: {
                    acceptanceFramesMatch($0.frame, resolvedFrame)
                }) else { continue }
                let candidate = unresolved.remove(at: index)
                let canResolveHittability = acceptanceFrameIsInViewport(resolvedFrame, viewport: applicationFrame)
                acceptanceAppendStateRecord(
                    candidate: candidate,
                    hittable: canResolveHittability ? element.isHittable : false,
                    enabled: element.isEnabled,
                    source: canResolveHittability ? "xctest" : "outsideViewport",
                    records: &records,
                    serializationErrorCount: &serializationErrorCount
                )
            }
            for candidate in unresolved {
                conservativeRecordCount += 1
                acceptanceAppendStateRecord(
                    candidate: candidate,
                    hittable: true,
                    enabled: true,
                    source: "unresolvedConservative",
                    records: &records,
                    serializationErrorCount: &serializationErrorCount
                )
            }
        }

        let durationMilliseconds = Int(Date.now.timeIntervalSince(startedAt) * 1_000)
        let summary: [String: Any] = [
            "schemaVersion": 1,
            "candidateCount": candidates.count,
            "recordCount": records.count,
            "serializationErrorCount": serializationErrorCount,
            "geometricNonHittableCount": geometricNonHittableCount,
            "conservativeRecordCount": conservativeRecordCount,
            "queryCount": queryCount,
            "queriedTypes": queriedTypes.sorted(),
            "durationMilliseconds": durationMilliseconds
        ]
        let summaryJSON = acceptanceJSONString(summary)
            ?? "{\"recordCount\":0,\"schemaVersion\":1,\"serializationErrorCount\":1}"
        records.append("ForgeFitAcceptanceStateSummary: \(summaryJSON)")
        return records.joined(separator: "\n")
    }

    private func acceptanceStateCandidates(
        in tree: String,
        interactiveTypes: [AcceptanceElementTypeQuery]
    ) -> [AcceptanceStateCandidate] {
        let typesByName = Dictionary(uniqueKeysWithValues: interactiveTypes.map { ($0.debugName, $0) })
        return tree.split(separator: "\n").compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            while let first = line.first, "→▿▹-".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let comma = line.firstIndex(of: ","),
                  let query = typesByName[String(line[..<comma])],
                  let frame = acceptanceFrame(in: line),
                  frame.width < 44 || frame.height < 44 else { return nil }
            return AcceptanceStateCandidate(
                query: query,
                identifier: acceptanceField("identifier", in: line),
                label: acceptanceField("label", in: line),
                frame: frame
            )
        }
    }

    private func acceptanceFrame(in line: String) -> CGRect? {
        guard let start = line.range(of: "{{"),
              let end = line.range(of: "}}", range: start.lowerBound..<line.endIndex) else { return nil }
        let values = String(line[start.lowerBound..<end.upperBound])
            .components(separatedBy: CharacterSet(charactersIn: "{}, "))
            .filter { !$0.isEmpty }
            .compactMap(Double.init)
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func acceptanceField(_ name: String, in line: String) -> String {
        let prefix = "\(name): '"
        guard let start = line.range(of: prefix) else { return "" }
        let remainder = line[start.upperBound...]
        guard let end = remainder.firstIndex(of: "'") else { return "" }
        return String(remainder[..<end])
    }

    private func acceptanceFrameIsInViewport(_ frame: CGRect, viewport: CGRect) -> Bool {
        let values = [
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            viewport.origin.x, viewport.origin.y, viewport.size.width, viewport.size.height
        ]
        guard values.allSatisfy(\.isFinite) else { return false }
        let intersection = frame.intersection(viewport)
        return !intersection.isNull
            && !intersection.isEmpty
            && intersection.width >= 1
            && intersection.height >= 1
    }

    private func acceptanceFramesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= 1
            && abs(lhs.origin.y - rhs.origin.y) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func acceptanceAppendStateRecord(
        candidate: AcceptanceStateCandidate,
        hittable: Bool,
        enabled: Bool,
        source: String,
        records: inout [String],
        serializationErrorCount: inout Int
    ) {
        let object: [String: Any] = [
            "type": candidate.query.debugName,
            "identifier": candidate.identifier,
            "label": candidate.label,
            "frame": [
                "x": Double(candidate.frame.origin.x),
                "y": Double(candidate.frame.origin.y),
                "width": Double(candidate.frame.width),
                "height": Double(candidate.frame.height)
            ],
            "exists": true,
            "hittable": hittable,
            "hittabilitySource": source,
            "enabled": enabled
        ]
        guard let json = acceptanceJSONString(object) else {
            serializationErrorCount += 1
            return
        }
        records.append("ForgeFitAcceptanceState: \(json)")
    }

    private func acceptanceJSONString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
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

    func testCase(
        _ testCase: XCTestCase,
        didFailWithDescription description: String,
        inFile filePath: String?,
        atLine lineNumber: Int
    ) {
        guard isEnabled else { return }
        let testIdentifier = normalizeTestIdentifier(testCase.name, sourceFile: "")
        let session = sessions[testIdentifier] ?? (sessions.count == 1 ? sessions.values.first : nil)
        session?.failures.append(AcceptanceFailureEvidence(
            phase: .assertion,
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

    private func finish(testIdentifier: String, succeeded: Bool) {
        guard let session = sessions.removeValue(forKey: testIdentifier) else { return }
        if currentScenarioID == testIdentifier {
            currentScenarioID = nil
        }
        if let pending = session.pendingExpectation {
            session.failures.append(AcceptanceFailureEvidence(
                phase: pending.phase,
                message: "declaredButUnused: no wrapped action consumed this expectation",
                checkpointID: nil,
                sourceFile: pending.sourceFile,
                sourceLine: pending.sourceLine
            ))
            session.pendingExpectation = nil
        }

        let scenario = AcceptanceScenario(
            id: session.scenarioID,
            title: "Human-like replay: \(session.scenarioID)",
            purpose: "Inspect the rendered result after every deterministic user action.",
            fixtureArguments: [],
            checkpoints: session.evidence.map(\.checkpoint)
        )
        let artifactFiles = Array(session.artifactFiles).sorted() + ["manifest.json", "judge-request.json"]
        let failedCheckpointCount = session.evidence.filter { $0.outcome == .fail }.count
        let declaredButUnusedCount = session.failures.filter {
            $0.message.hasPrefix("declaredButUnused:")
        }.count
        let setupBlocked = session.failures.contains { $0.phase == .setup }
            || session.evidence.contains { $0.outcome == .blocked }
        let assertionFailed = session.failures.contains { $0.phase == .assertion }
            || session.evidence.contains { $0.outcome == .fail }
            || declaredButUnusedCount > 0
        let unverifiedCheckpointCount = session.evidence.filter { $0.outcome == .unverified }.count
        let environment = AcceptanceEnvironment(
            platform: "iOS Simulator",
            device: "unknown",
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            locale: Locale.current.identifier,
            timeZone: TimeZone.current.identifier,
            appearance: "system",
            dynamicType: "default",
            gitCommit: AcceptanceRunConfiguration.gitCommit,
            gitDirty: AcceptanceRunConfiguration.gitDirty
        )
        let outcome: AcceptanceOutcome = assertionFailed || (!succeeded && !setupBlocked)
            ? .fail
            : setupBlocked
                ? .blocked
                : unverifiedCheckpointCount > 0
                    ? .unverified
                    : .pass
        let manifest = AcceptanceRunManifest(
            schemaVersion: 3,
            runID: session.runID,
            startedAt: session.evidence.first?.startedAt ?? Date(),
            finishedAt: Date(),
            scenario: scenario,
            environment: environment,
            outcome: outcome,
            checkpointCount: session.evidence.count,
            failedCheckpointCount: failedCheckpointCount + session.failures.filter { $0.phase == .assertion && $0.checkpointID == nil }.count,
            artifactFiles: artifactFiles,
            failures: session.failures,
            unverifiedCheckpointCount: unverifiedCheckpointCount,
            declaredButUnusedCount: declaredButUnusedCount,
            rubricID: AcceptanceRunConfiguration.rubricID,
            rubricVersion: AcceptanceRunConfiguration.rubricVersion
        )

        let judgeRequest = AcceptanceJudgeRequest(
            schemaVersion: 3,
            scenario: scenario,
            environment: environment,
            checkpointEvidence: session.evidence,
            judgeInstructions: "Use the checked-in forgefit-ai-acceptance rubric. Review every checkpoint in order, inspect before/after evidence, honor setup versus assertion phases, run the automated tree-lint findings, and report only observable issues. Return one JSON object matching responseSchema.",
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
            XCTFail("Could not write human-like acceptance manifest for \(testIdentifier): \(error.localizedDescription)")
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
        // A clean automation launch rebuilds the bundled exercise catalog
        // behind the app's explicit preparation barrier. Give that one action
        // enough time to reach seeded UI; ordinary interactions should still
        // fail quickly when they never settle.
        let idleTimeout = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_IDLE_TIMEOUT"]
            .flatMap(TimeInterval.init)
            ?? (action == "launch" ? 60.0 : 2.0)
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

/// Declare the expected state for the next wrapped user action.
func acceptanceExpect(
    _ visibleIdentifiers: [String] = [],
    visibleLabels: [String] = [],
    phase: AcceptanceCheckpointPhase = .assertion,
    invariants: [String] = [],
    oracles: [AcceptanceOracle] = [],
    file: StaticString = #fileID,
    line: UInt = #line
) {
    AcceptanceHumanActionRecorder.shared.expect(
        visibleIdentifiers: visibleIdentifiers,
        visibleLabels: visibleLabels,
        phase: phase,
        invariants: invariants,
        oracles: oracles,
        sourceFile: file,
        sourceLine: line
    )
}

/// Setup failures are recorded as blocked evidence and stop the flow without
/// presenting the fixture failure as a product defect.
@discardableResult
func acceptanceRequire(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) throws -> Bool {
    guard condition() else {
        let text = message()
        AcceptanceHumanActionRecorder.shared.recordFailure(
            phase: .setup,
            message: text,
            sourceFile: file,
            sourceLine: line
        )
        throw XCTSkip("Acceptance setup blocked: \(text)")
    }
    return true
}

/// Product assertions keep their first failed checkpoint in the evidence
/// manifest instead of reducing the failure to a test-level boolean.
@discardableResult
func acceptanceAssert(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String,
    file: StaticString = #fileID,
    line: UInt = #line
) -> Bool {
    guard condition() else {
        let text = message()
        AcceptanceHumanActionRecorder.shared.recordFailure(
            phase: .assertion,
            message: text,
            sourceFile: file,
            sourceLine: line
        )
        XCTFail(text, file: file, line: line)
        return false
    }
    return true
}

func acceptanceSetup(
    _ name: String,
    file: StaticString = #fileID,
    line: UInt = #line,
    operation: () throws -> Void
) throws {
    do {
        try operation()
    } catch {
        AcceptanceHumanActionRecorder.shared.recordFailure(
            phase: .setup,
            message: "\(name): \(error.localizedDescription)",
            sourceFile: file,
            sourceLine: line
        )
        throw error
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

    func acceptanceClearAndType(_ text: String, file: StaticString = #fileID, line: UInt = #line) {
        AcceptanceHumanActionRecorder.shared.perform(
            action: "clearAndType",
            target: self,
            sourceFile: file,
            sourceLine: line
        ) {
            self.tap()
            if let currentValue = self.value as? String, !currentValue.isEmpty {
                self.typeText(String(repeating: "\u{8}", count: currentValue.count))
            }
            self.typeText(text)
        }
    }

    func acceptanceTapScoped(
        in container: XCUIElement,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let identifier = self.identifier
        let scoped = !identifier.isEmpty
            ? container.descendants(matching: .any)[identifier].firstMatch
            : container.descendants(matching: .any)[self.label].firstMatch
        scoped.acceptanceTap(file: file, line: line)
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
    func acceptanceExpect(
        _ visibleIdentifiers: [String] = [],
        visibleLabels: [String] = [],
        phase: AcceptanceCheckpointPhase = .assertion,
        invariants: [String] = [],
        oracles: [AcceptanceOracle] = [],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        AcceptanceHumanActionRecorder.shared.expect(
            visibleIdentifiers: visibleIdentifiers,
            visibleLabels: visibleLabels,
            phase: phase,
            invariants: invariants,
            oracles: oracles,
            sourceFile: file,
            sourceLine: line
        )
    }

    func acceptanceElement(_ identifier: String, in container: XCUIElement) -> XCUIElement {
        container.descendants(matching: .any)[identifier].firstMatch
    }

    func acceptanceButton(_ identifier: String, in container: XCUIElement) -> XCUIElement {
        container.buttons[identifier].firstMatch
    }

    @discardableResult
    func acceptanceWaitForIdle(timeout: TimeInterval = 15) -> Bool {
        let foregroundWait = min(max(timeout, 0), 5)
        guard wait(for: .runningForeground, timeout: foregroundWait) else { return false }
        let deadline = Date().addingTimeInterval(max(0, timeout - foregroundWait))
        var stableSamples = 0
        while Date() < deadline {
            let hasVisibleActivity = activityIndicators.allElementsBoundByIndex.contains {
                $0.exists && $0.isHittable
            }
            if hasVisibleActivity {
                stableSamples = 0
            } else {
                stableSamples += 1
                if stableSamples >= 2 { return true }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

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
