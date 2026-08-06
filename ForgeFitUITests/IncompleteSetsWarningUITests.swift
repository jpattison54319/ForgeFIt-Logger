import XCTest

/// The finish-time guard against an accidentally skipped set. Unit coverage
/// lives in `IncompleteWorkSummaryTests`; this proves the alert actually
/// reaches the screen and that both of its answers work.
final class IncompleteSetsWarningUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func tapWhenReady(_ el: XCUIElement, timeout: TimeInterval = 8) {
        XCTAssertTrue(el.waitForExistence(timeout: timeout), "Missing \(el)")
        if !el.isHittable { XCUIApplication().swipeUp() }
        el.tap()
    }

    private func launchIntoWorkout() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "-didOnboard", "YES",
            "--auto-start-routine",
            "-weightUnitRaw", "lb",
        ]
        app.launch()
        XCTAssertTrue(element(app, "finish-workout-button").waitForExistence(timeout: 20),
                      "Expected the live logger.")
        return app
    }

    /// The starter routine is auto-started and nothing is ticked, so Finish
    /// must stop and say so rather than silently dropping the session's work.
    @MainActor
    func testFinishingWithUntickedSetsWarnsBeforeTheSummary() throws {
        let app = launchIntoWorkout()
        tapWhenReady(element(app, "finish-workout-button"))

        XCTAssertTrue(app.staticTexts["Unfinished sets"].waitForExistence(timeout: 5),
                      "Expected the unfinished-sets warning.")
        XCTAssertTrue(app.buttons["Finish Anyway"].exists)
        XCTAssertTrue(app.buttons["Keep Logging"].exists)
        XCTAssertFalse(element(app, "save-workout-button").exists,
                       "The summary must not appear until the warning is answered.")
    }

    /// Keep Logging returns to the workout with everything intact — the whole
    /// point is the chance to go back and tick the set you missed.
    @MainActor
    func testKeepLoggingReturnsToTheWorkout() throws {
        let app = launchIntoWorkout()
        tapWhenReady(element(app, "finish-workout-button"))
        XCTAssertTrue(app.buttons["Keep Logging"].waitForExistence(timeout: 5))
        app.buttons["Keep Logging"].tap()

        XCTAssertTrue(element(app, "finish-workout-button").waitForExistence(timeout: 5),
                      "Expected to be back in the live logger.")
        XCTAssertFalse(element(app, "save-workout-button").exists,
                       "Keep Logging must not fall through to the summary.")
    }

    /// Finishing early on purpose stays one tap away.
    @MainActor
    func testFinishAnywayProceedsToTheSummary() throws {
        let app = launchIntoWorkout()
        tapWhenReady(element(app, "finish-workout-button"))
        XCTAssertTrue(app.buttons["Finish Anyway"].waitForExistence(timeout: 5))
        app.buttons["Finish Anyway"].tap()

        XCTAssertTrue(element(app, "save-workout-button").waitForExistence(timeout: 8),
                      "Expected the post-workout summary after Finish Anyway.")
    }
}
