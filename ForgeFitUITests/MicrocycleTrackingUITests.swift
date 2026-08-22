import XCTest

final class MicrocycleTrackingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testProfileGroupsSeparateRunsAndOpensReadOnlyCycleDetail() {
        let app = launch(initialTab: "profile")

        let history = app.buttons["profile-microcycle-history"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.acceptanceTap()

        XCTAssertTrue(app.navigationBars["Microcycle History"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label == 'Strength Cycle'")
        ).count, 2)
        XCTAssertTrue(app.staticTexts["TRACKING"].exists)
        XCTAssertTrue(app.staticTexts["STOPPED"].exists)

        let window = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'microcycle-history-window-'")
        ).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Workouts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["microcycle-log-rest-day"].exists)
        XCTAssertFalse(app.buttons["microcycle-remove-day-backfill"].exists)
    }

    @MainActor
    func testMakingMicrocycleActiveOffersTrackingAndExplainsDayTarget() {
        let app = launch(initialTab: "workout")
        let options = app.buttons["Folder options for Conditioning Cycle"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.acceptanceTap()

        let activate = app.buttons["Set as Active Microcycle"].firstMatch
        XCTAssertTrue(activate.waitForExistence(timeout: 3))
        activate.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Track \"Conditioning Cycle\"?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'calendar days each cycle lasts'")
        ).firstMatch.exists)
        let target = app.buttons["Set Day Target"].firstMatch
        XCTAssertTrue(target.exists)
        target.acceptanceTap()

        XCTAssertTrue(app.navigationBars["Conditioning Cycle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Each cycle lasts this many calendar days before the next one begins."].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Starting this tracker stops Strength Cycle'")
        ).firstMatch.exists)
    }

    @MainActor
    func testPreviousWindowInLiveTrackerOpensReadOnlyDetail() {
        let app = launch(initialTab: "workout")
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.acceptanceTap()

        let previous = app.buttons["microcycle-previous-window-1"].firstMatch
        scrollToHittable(previous, in: app)
        previous.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Workouts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["microcycle-log-rest-day"].exists)
        XCTAssertFalse(app.buttons["stop-microcycle-tracking"].exists)
    }

    @MainActor
    func testFirstStopExplainsHistoryAndOpensItFromProfile() {
        let app = launch(
            initialTab: "workout",
            additionalArguments: ["-microcycleHistoryEducationShown", "NO"]
        )
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.acceptanceTap()

        let stop = app.buttons["stop-microcycle-tracking"].firstMatch
        scrollToHittable(stop, in: app)
        stop.acceptanceTap()
        let confirm = app.buttons["Stop Tracking"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Microcycle history saved"].waitForExistence(timeout: 5))
        let viewHistory = app.buttons["View History"].firstMatch
        XCTAssertTrue(viewHistory.waitForExistence(timeout: 3))
        viewHistory.acceptanceTap()

        XCTAssertTrue(app.navigationBars["Microcycle History"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Microcycle History"].exists)
    }

    @MainActor
    private func launch(
        initialTab: String,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--seed-microcycle-tracking",
            "-didOnboard", "YES",
            "-initialTab", initialTab,
            "-weightUnitRaw", "kg",
        ] + additionalArguments
        app.acceptanceLaunch()
        return app
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 8
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            app.acceptanceSwipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
