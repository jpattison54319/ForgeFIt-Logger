import XCTest

final class SleepTargetUITests: XCTestCase {
    @MainActor
    func testHomeSleepDetailOpensSleepTargetEditor() {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "-didOnboard", "YES",
            "--seed-partial-sleep-demo",
        ]
        app.launchEnvironment["FORGEFIT_PARTIAL_SLEEP_DEMO"] = "1"
        app.acceptanceLaunch()

        let sleepTile = app.descendants(matching: .any)["home-sleep-card"].firstMatch
        XCTAssertTrue(sleepTile.waitForExistence(timeout: 10))
        sleepTile.acceptanceTap()

        let targetButton = app.buttons["sleep-target-edit"].firstMatch
        XCTAssertTrue(targetButton.waitForExistence(timeout: 5))
        targetButton.acceptanceTap()

        XCTAssertTrue(
            app.descendants(matching: .any)["sleep-target-picker"].firstMatch
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["sleep-target-save"].firstMatch.exists)
    }
}
