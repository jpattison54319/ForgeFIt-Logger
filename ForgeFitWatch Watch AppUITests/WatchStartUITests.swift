import XCTest

@MainActor
final class WatchStartUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPendingStartDisablesDuplicatesThenOffersRecovery() throws {
        let app = application(scenario: #function)
        app.launchArguments.append("--seed-watch-start-timeout")
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"])
        app.watchAcceptanceLaunch()
        XCTAssertTrue(app.buttons["watch-empty-workout"].waitForExistence(timeout: 15))
        watchAcceptanceExpect(["watch-start-status"], visibleLabels: ["Starting on iPhone…"])
        app.buttons["watch-empty-workout"].watchAcceptanceTap()
        XCTAssertFalse(app.buttons["watch-empty-workout"].isEnabled)
        XCTAssertTrue(app.buttons["watch-start-retry-sync"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["iPhone did not confirm the start."].exists)
        XCTAssertFalse(app.descendants(matching: .any)["watch-active-workout"].exists)
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"])
        app.buttons["watch-start-retry-sync"].watchAcceptanceTap()
        XCTAssertFalse(app.buttons["watch-start-retry-sync"].exists)
        XCTAssertTrue(app.buttons["watch-empty-workout"].isEnabled)
    }

    func testRoutineStartShowsItsConfirmedExercises() throws {
        let app = application(scenario: #function)
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"])
        app.watchAcceptanceLaunch()
        watchAcceptanceExpect(["watch-routine-Push Day"])
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.83))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.44))
        from.watchAcceptanceSlowDrag(to: to)
        XCTAssertTrue(app.buttons["watch-routine-Push Day"].isHittable)
        watchAcceptanceExpect(["watch-exercises-page", "watch-exercise-Barbell Bench Press"])
        app.buttons["watch-routine-Push Day"].watchAcceptanceTap()
        XCTAssertTrue(app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["watch-start-issue"].exists)
    }

    func testEmptyStartShowsTheConfirmedWorkout() throws {
        let app = application(scenario: #function)
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"])
        app.watchAcceptanceLaunch()
        watchAcceptanceExpect(["watch-active-workout", "watch-exercises-page"], visibleLabels: ["Starting HR…"])
        app.buttons["watch-empty-workout"].watchAcceptanceTapAndWait(for: app.staticTexts["Starting HR…"])
        XCTAssertFalse(app.descendants(matching: .any)["watch-start-issue"].exists)
        watchAcceptanceExpect(["watch-controls-page"], visibleLabels: ["Finish", "Discard"])
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(app.buttons["Finish"].isEnabled)
        XCTAssertTrue(app.buttons["watch-discard-workout"].isEnabled)
        watchAcceptanceExpect(visibleLabels: ["Discard workout?", "Discard"])
        app.buttons["watch-discard-workout"].watchAcceptanceTap()
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"])
        app.tables.buttons["Discard"].watchAcceptanceTapAndWait(for: app.buttons["watch-empty-workout"])
        XCTAssertFalse(app.descendants(matching: .any)["watch-active-workout"].exists)
    }

    private func application(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(app, scenarioID: "WatchStartUITests/\(scenario.replacingOccurrences(of: "()", with: ""))")
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-start-recovery"]
        return app
    }
}
