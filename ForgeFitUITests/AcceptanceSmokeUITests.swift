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
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = scenario.fixtureArguments
        let home = scenario.checkpoints[0]
        acceptanceExpect(
            home.expectedVisibleIdentifiers,
            visibleLabels: home.expectedVisibleLabels,
            phase: home.phase,
            invariants: home.invariants
        )
        app.acceptanceLaunch()

        try assertCheckpoint(home, in: app)

        let tabCheckpoints = Array(scenario.checkpoints.dropFirst())
        for checkpoint in tabCheckpoints {
            let tab = app.buttons[checkpoint.expectedVisibleIdentifiers[0]].firstMatch
            guard acceptanceAssert(
                tab.waitForExistence(timeout: 15),
                "Missing \(checkpoint.title) control"
            ) else { return }
            guard acceptanceAssert(tab.isHittable, "\(checkpoint.title) control is not hittable") else { return }
            acceptanceExpect(
                checkpoint.expectedVisibleIdentifiers,
                visibleLabels: checkpoint.expectedVisibleLabels,
                phase: checkpoint.phase,
                invariants: checkpoint.invariants
            )
            tab.acceptanceTap()
            try assertCheckpoint(checkpoint, in: app)
        }
    }

    private func assertCheckpoint(_ checkpoint: AcceptanceCheckpoint, in app: XCUIApplication) throws {
        for identifier in checkpoint.expectedVisibleIdentifiers {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            guard acceptanceAssert(
                element.waitForExistence(timeout: 15),
                "Expected identifier \(identifier) at \(checkpoint.id)"
            ) else { return }
        }
        for label in checkpoint.expectedVisibleLabels {
            let text = app.staticTexts[label].firstMatch
            let button = app.buttons[label].firstMatch
            guard acceptanceAssert(
                text.exists || button.exists,
                "Expected label \(label) at \(checkpoint.id)"
            ) else { return }
        }
    }
}
