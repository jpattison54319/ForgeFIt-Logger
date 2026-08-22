import XCTest

/// A first AI-judge-ready vertical slice. More journeys should be added to the
/// catalog and runner as contracts are reviewed; this test stays intentionally
/// small so its evidence format remains easy to validate and replay.
final class AcceptanceSmokeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRepresentativeAppTour() throws {
        let scenario = AcceptanceScenarioCatalog.representativeTour
        let runStartedAt = Date()
        let writer = try AcceptanceEvidenceWriter(scenarioID: scenario.id)
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = scenario.fixtureArguments
        app.launchEnvironment["FORGEFIT_ACCEPTANCE_RUN_ID"] = writer.runID
        app.acceptanceLaunch()

        defer {
            do {
                try writer.finish(scenario: scenario, startedAt: runStartedAt)
            } catch {
                XCTFail("Could not write acceptance evidence: \(error.localizedDescription)")
            }
        }

        let home = scenario.checkpoints[0]
        try assertCheckpoint(home, in: app)
        try writer.record(checkpoint: home, app: app, outcome: .pass, startedAt: .now)

        let tabCheckpoints = Array(scenario.checkpoints.dropFirst())
        for checkpoint in tabCheckpoints {
            let tab = app.buttons[checkpoint.expectedVisibleIdentifiers[0]].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15), "Missing \(checkpoint.title) control")
            XCTAssertTrue(tab.isHittable, "\(checkpoint.title) control is not hittable")
            tab.acceptanceTap()
            try assertCheckpoint(checkpoint, in: app)
            try writer.record(checkpoint: checkpoint, app: app, outcome: .pass, startedAt: .now)
        }
    }

    private func assertCheckpoint(_ checkpoint: AcceptanceCheckpoint, in app: XCUIApplication) throws {
        for identifier in checkpoint.expectedVisibleIdentifiers {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 15), "Expected identifier \(identifier) at \(checkpoint.id)")
        }
        for label in checkpoint.expectedVisibleLabels {
            let text = app.staticTexts[label].firstMatch
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(text.exists || button.exists, "Expected label \(label) at \(checkpoint.id)")
        }
    }
}
