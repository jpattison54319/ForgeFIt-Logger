//
//  ForgeFitWatch_Watch_AppUITests.swift
//  ForgeFitWatch Watch AppUITests
//
//  Created by James Pattison on 6/29/26.
//

import Foundation
import XCTest

private struct WatchAcceptanceManifest: Codable {
    let schemaVersion: Int
    let scenarioID: String
    let runID: String
    let startedAt: Date
    let finishedAt: Date
    let checkpoints: [String]
}

private struct WatchAcceptanceScenario: Codable {
    let id: String
    let title: String
    let purpose: String
    let fixtureArguments: [String]
    let checkpoints: [WatchAcceptanceCheckpoint]
}

private struct WatchAcceptanceCheckpoint: Codable {
    let id: String
    let title: String
    let action: String
    let expectedVisibleIdentifiers: [String]
    let expectedVisibleLabels: [String]
    let screenshotRequired: Bool
}

private struct WatchAcceptanceCheckpointEvidence: Codable {
    let scenarioID: String
    let checkpoint: WatchAcceptanceCheckpoint
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

private struct WatchAcceptanceJudgeRequest: Codable {
    let schemaVersion: Int
    let scenario: WatchAcceptanceScenario
    let checkpointEvidence: [WatchAcceptanceCheckpointEvidence]
    let judgeInstructions: String
    let responseSchema: WatchAcceptanceResponseSchema
}

private struct WatchAcceptanceResponseSchema: Codable {
    let outcome: String
    let findings: [WatchAcceptanceFinding]
}

private struct WatchAcceptanceFinding: Codable {
    let severity: String
    let category: String
    let observation: String
    let expected: String
    let actual: String
    let confidence: Double
    let checkpointID: String
    let evidencePaths: [String]
}

private final class WatchAcceptanceEvidenceWriter {
    let scenarioID: String
    let runID = UUID().uuidString.lowercased()
    let rootURL: URL
    private var checkpoints: [String] = []
    private var evidence: [WatchAcceptanceCheckpointEvidence] = []

    init(scenarioID: String) throws {
        self.scenarioID = scenarioID
        let basePath = ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ARTIFACTS"]
            ?? "/tmp/forgefit-acceptance"
        rootURL = URL(fileURLWithPath: basePath, isDirectory: true)
            .appendingPathComponent(scenarioID, isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    @MainActor
    func capture(_ checkpoint: WatchAcceptanceCheckpoint, app: XCUIApplication) throws {
        let checkpointID = checkpoint.id
        let screenshotURL = rootURL.appendingPathComponent("screenshots/\(checkpointID).png")
        try FileManager.default.createDirectory(
            at: screenshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let screenshot = app.screenshot()
        XCTContext.runActivity(named: "Capture \(checkpointID)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = checkpointID
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        try screenshot.pngRepresentation.write(to: screenshotURL, options: .atomic)

        let treeURL = rootURL.appendingPathComponent("accessibility/\(checkpointID).txt")
        try FileManager.default.createDirectory(
            at: treeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try app.debugDescription.write(to: treeURL, atomically: true, encoding: .utf8)
        checkpoints.append(checkpointID)

        let observedIdentifiers = checkpoint.expectedVisibleIdentifiers.filter {
            app.descendants(matching: .any)[$0].firstMatch.exists
        }
        let observedLabels = checkpoint.expectedVisibleLabels.filter {
            app.staticTexts[$0].firstMatch.exists || app.buttons[$0].firstMatch.exists
        }
        evidence.append(WatchAcceptanceCheckpointEvidence(
            scenarioID: scenarioID,
            checkpoint: checkpoint,
            outcome: "pass",
            startedAt: .now,
            finishedAt: .now,
            observedIdentifiers: observedIdentifiers,
            observedLabels: observedLabels,
            missingIdentifiers: checkpoint.expectedVisibleIdentifiers.filter {
                !observedIdentifiers.contains($0)
            },
            missingLabels: checkpoint.expectedVisibleLabels.filter {
                !observedLabels.contains($0)
            },
            screenshotFile: "screenshots/\(checkpointID).png",
            accessibilityTreeFile: "accessibility/\(checkpointID).txt",
            notes: []
        ))
    }

    func finish(scenario: WatchAcceptanceScenario, startedAt: Date) throws {
        let manifest = WatchAcceptanceManifest(
            schemaVersion: 1,
            scenarioID: scenarioID,
            runID: runID,
            startedAt: startedAt,
            finishedAt: .now,
            checkpoints: checkpoints
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(
            to: rootURL.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let judgeRequest = WatchAcceptanceJudgeRequest(
            schemaVersion: 1,
            scenario: scenario,
            checkpointEvidence: evidence,
            judgeInstructions: "Review every screenshot and accessibility tree. Report only observable issues. Distinguish confirmed failures from suspects. Check functionality, visual hierarchy, copy, affordances, accessibility, and consistency with the checkpoint contract. Return one JSON object matching responseSchema. Use an empty findings array when no issue is observed.",
            responseSchema: WatchAcceptanceResponseSchema(
                outcome: "pass | fail | suspect | blocked",
                findings: [WatchAcceptanceFinding(
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
        try encoder.encode(judgeRequest).write(
            to: rootURL.appendingPathComponent("judge-request.json"),
            options: .atomic
        )
    }
}

final class ForgeFitWatch_Watch_AppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testWatchHomeDemo() throws {
        let startedAt = Date()
        let evidence = try WatchAcceptanceEvidenceWriter(scenarioID: "watch-home-demo")
        let scenario = WatchAcceptanceScenario(
            id: "watch-home-demo",
            title: "Watch home demo",
            purpose: "Verify the Watch home surface renders an empty-workout path and a synced routine from deterministic state.",
            fixtureArguments: ["--seed-watch-demo"],
            checkpoints: [
                WatchAcceptanceCheckpoint(
                    id: "watch-routines",
                    title: "Synced routines are visible",
                    action: "Launch the Watch from a seeded state, then scroll to the routine list.",
                    expectedVisibleIdentifiers: ["watch-home", "watch-routine-Push Day"],
                    expectedVisibleLabels: ["Push Day"],
                    screenshotRequired: true
                )
            ]
        )
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(
            app,
            scenarioID: "ForgeFitWatch_Watch_AppUITests/testWatchHomeDemo"
        )
        app.launchArguments = scenario.fixtureArguments
        app.launchEnvironment["FORGEFIT_ACCEPTANCE_RUN_ID"] = evidence.runID
        app.watchAcceptanceLaunch()

        defer {
            do {
                try evidence.finish(scenario: scenario, startedAt: startedAt)
            } catch {
                XCTFail("Could not write Watch acceptance evidence: \(error.localizedDescription)")
            }
        }

        XCTAssertTrue(
            app.descendants(matching: .any)["watch-home"].firstMatch.waitForExistence(timeout: 15),
            "The seeded Watch home must render"
        )
        XCTAssertTrue(
            app.buttons["watch-empty-workout"].firstMatch.exists,
            "The Watch must expose the visible Empty Workout action"
        )
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(
            app.buttons["watch-routine-Push Day"].firstMatch.waitForExistence(timeout: 10),
            "The Watch must render the synced Push Day routine"
        )
        try evidence.capture(scenario.checkpoints[0], app: app)
    }

    @MainActor
    func testWatchActiveWorkoutDemo() throws {
        let startedAt = Date()
        let evidence = try WatchAcceptanceEvidenceWriter(scenarioID: "watch-active-workout-demo")
        let scenario = WatchAcceptanceScenario(
            id: "watch-active-workout-demo",
            title: "Watch active workout demo",
            purpose: "Verify the Watch active workout, set completion, controls, and destructive discard confirmation from deterministic state.",
            fixtureArguments: ["--seed-watch-demo", "--seed-watch-demo-active"],
            checkpoints: [
                WatchAcceptanceCheckpoint(
                    id: "watch-active-exercises",
                    title: "Active exercises are visible",
                    action: "Launch the Watch with a seeded active workout.",
                    expectedVisibleIdentifiers: ["watch-active-workout", "watch-exercises-page", "watch-exercise-Barbell Bench Press"],
                    expectedVisibleLabels: [],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-set-list",
                    title: "Exercise set list is visible",
                    action: "Open the seeded exercise and complete the third set from the visible set list.",
                    expectedVisibleIdentifiers: ["watch-set-list", "watch-toggle-set-3"],
                    expectedVisibleLabels: [],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-controls",
                    title: "Workout controls are visible",
                    action: "Return to the exercise page and navigate to the visible controls page.",
                    expectedVisibleIdentifiers: ["watch-controls-page"],
                    expectedVisibleLabels: ["Discard"],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-discard-confirmation",
                    title: "Discard is confirmable",
                    action: "Open Discard and inspect the warning before closing it.",
                    expectedVisibleIdentifiers: ["watch-controls-page"],
                    expectedVisibleLabels: ["Discard workout?", "All logged sets from this session will be lost."],
                    screenshotRequired: true
                )
            ]
        )
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(
            app,
            scenarioID: "ForgeFitWatch_Watch_AppUITests/testWatchActiveWorkoutDemo"
        )
        app.launchArguments = scenario.fixtureArguments
        app.launchEnvironment["FORGEFIT_ACCEPTANCE_RUN_ID"] = evidence.runID
        app.watchAcceptanceLaunch()

        defer {
            do {
                try evidence.finish(scenario: scenario, startedAt: startedAt)
            } catch {
                XCTFail("Could not write Watch acceptance evidence: \(error.localizedDescription)")
            }
        }

        XCTAssertTrue(
            app.descendants(matching: .any)["watch-active-workout"].firstMatch.waitForExistence(timeout: 15),
            "The seeded active Watch workout must render"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercises-page"].firstMatch.exists,
            "The Watch must begin on the exercise/set page"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists,
            "The Watch must render the seeded exercise"
        )
        try evidence.capture(scenario.checkpoints[0], app: app)

        let exercise = app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch
        XCTAssertTrue(exercise.isHittable, "The seeded exercise must be interactable")
        exercise.watchAcceptanceTap()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-set-list"].firstMatch.waitForExistence(timeout: 10),
            "Opening an exercise must show its set list"
        )

        let thirdSet = app.descendants(matching: .any)["watch-toggle-set-3"].firstMatch
        XCTAssertTrue(thirdSet.waitForExistence(timeout: 10), "The third set must be directly completable")
        XCTAssertTrue(thirdSet.isHittable, "The third set control must be hittable")
        thirdSet.watchAcceptanceTap()
        try evidence.capture(scenario.checkpoints[1], app: app)

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The set list must provide visible back navigation")
        back.watchAcceptanceTap()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercises-page"].firstMatch.waitForExistence(timeout: 10),
            "Returning from set details must restore the exercise page"
        )

        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.52))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12))
        pageStart.watchAcceptancePress(forDuration: 0.1, thenDragTo: pageEnd)
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-controls-page"].firstMatch.waitForExistence(timeout: 10),
            "The active workout must expose controls as a visible page"
        )
        try evidence.capture(scenario.checkpoints[2], app: app)

        let discard = app.buttons["Discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 10), "Discard must be visible in the controls page")
        discard.watchAcceptanceTap()
        XCTAssertTrue(app.staticTexts["Discard workout?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All logged sets from this session will be lost."].exists)
        try evidence.capture(scenario.checkpoints[3], app: app)
        let cancel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Close", "Cancel", "Dismiss"]))
            .firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The discard dialog must provide a visible close action")
        cancel.watchAcceptanceTap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().watchAcceptanceLaunch()
        }
    }
}
