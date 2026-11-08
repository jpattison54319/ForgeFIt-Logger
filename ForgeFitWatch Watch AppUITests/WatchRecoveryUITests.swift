import XCTest

@MainActor
final class WatchRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testRetryRestoresThePhoneWorkout() throws {
        let app = application(scenario: #function, active: true)
        watchAcceptanceExpect(["watch-recovery-status", "watch-retry-sync"])
        app.watchAcceptanceLaunch()
        XCTAssertTrue(app.buttons["watch-retry-sync"].waitForExistence(timeout: 15))
        watchAcceptanceExpect(["watch-exercises-page", "watch-exercise-Barbell Bench Press"])
        app.buttons["watch-retry-sync"].watchAcceptanceTap()
        XCTAssertTrue(app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists)
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.52))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12))
        watchAcceptanceExpect(["watch-exercises-page"])
        pageStart.watchAcceptancePress(forDuration: 0.1, thenDragTo: pageEnd)
        watchAcceptanceExpect(["watch-controls-page"], visibleLabels: ["Finish", "Discard"])
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(app.buttons["Finish"].isEnabled)
        let banner = app.descendants(matching: .any)["watch-rest-banner"].firstMatch
        XCTAssertLessThanOrEqual(banner.frame.maxY, app.buttons["Finish"].frame.minY)
        XCTAssertTrue(app.buttons["watch-discard-workout"].isEnabled)
    }

    func testStopAndExplicitResumeDuringPendingHandoff() throws {
        let app = application(scenario: #function, active: true)
        watchAcceptanceExpect(["watch-retry-sync", "watch-stop-recording"])
        app.watchAcceptanceLaunch()
        let stop = app.buttons["watch-stop-recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        watchAcceptanceExpect(visibleLabels: ["Stop Recording", "Stops Watch recording without saving it to Health. Your phone workout is kept."])
        stop.watchAcceptanceTap()
        XCTAssertTrue(app.buttons["Stop Recording"].waitForExistence(timeout: 5))
        watchAcceptanceExpect(["watch-recovery-status", "watch-retry-sync"], visibleLabels: ["Stopped on Watch", "Resume on Watch"])
        app.buttons["Stop Recording"].watchAcceptanceTap()
        XCTAssertFalse(app.buttons["watch-stop-recording"].exists)
        XCTAssertEqual(app.buttons["watch-retry-sync"].label, "Resume on Watch")
        XCTAssertFalse(app.staticTexts["Starting HR…"].exists)
        watchAcceptanceExpect(["watch-exercises-page", "watch-exercise-Barbell Bench Press"])
        app.buttons["watch-retry-sync"].watchAcceptanceTap()
        XCTAssertTrue(app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists)
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
    }

    func testIdleConnectionIssueKeepsHomeQuiet() throws {
        let app = application(scenario: #function, active: false)
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"], visibleLabels: ["Readiness score"])
        app.watchAcceptanceLaunch()
        XCTAssertTrue(app.buttons["watch-empty-workout"].exists)
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        XCTAssertFalse(app.buttons["watch-stop-recording"].exists)
    }

    func testBriefStartupFailureNeverShowsRetry() throws {
        let app = application(scenario: #function, active: true)
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-demo-active", "--seed-watch-transient-sync"]
        watchAcceptanceExpect(["watch-active-workout"])
        app.watchAcceptanceLaunch()
        // Includes both the failed request and the automatic phone reply.
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        XCTAssertFalse(app.buttons["watch-retry-sync"].waitForExistence(timeout: 7))
        XCTAssertTrue(app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists)
        watchAcceptanceExpect(["watch-metrics-page"])
        app.watchAcceptanceSwipeDown()
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        watchAcceptanceExpect(["watch-exercises-page", "watch-exercise-Barbell Bench Press"])
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        XCTAssertFalse(app.staticTexts["Starting HR…"].exists)
    }

    func testCompletedTimedSetMirrorsTheRecordedDuration() throws {
        let app = application(scenario: #function, active: true)
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-demo-active", "--seed-watch-timed-hold"]
        watchAcceptanceExpect(["watch-exercise-Plank"])
        app.watchAcceptanceLaunch()
        let exercise = app.descendants(matching: .any)["watch-exercise-Plank"].firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 12))
        watchAcceptanceExpect(["watch-timed-set"])
        exercise.watchAcceptanceTap()
        let hold = app.descendants(matching: .any)["watch-timed-set"].firstMatch
        XCTAssertTrue(hold.waitForExistence(timeout: 5))
        XCTAssertTrue(hold.label.contains("1:05"))
        XCTAssertTrue(hold.label.contains("Completed"))
    }

    func testCompletedDistanceSetMirrorsTheSelectedUnit() throws {
        let app = application(scenario: #function, active: true)
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-demo-active", "--seed-watch-strength-distance"]
        watchAcceptanceExpect(["watch-exercise-Monster Walk"])
        app.watchAcceptanceLaunch()
        let exercise = app.descendants(matching: .any)["watch-exercise-Monster Walk"].firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 12))
        watchAcceptanceExpect(["watch-distance-set"])
        exercise.watchAcceptanceTap()
        let distance = app.descendants(matching: .any)["watch-distance-set"].firstMatch
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        XCTAssertTrue(distance.label.contains("98.43 ft"))
        XCTAssertTrue(distance.label.contains("Completed"))
    }

    func testFinishClearsRecoveryBeforeReturningHome() throws {
        let app = application(scenario: #function, active: true)
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-demo-active", "--seed-watch-finish-after-sync"]
        watchAcceptanceExpect(["watch-exercises-page", "watch-retry-sync"])
        app.watchAcceptanceLaunch()
        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.52))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12))
        watchAcceptanceExpect(["watch-exercises-page"])
        pageStart.watchAcceptancePress(forDuration: 0.1, thenDragTo: pageEnd)
        watchAcceptanceExpect(["watch-controls-page"], visibleLabels: ["Finish", "Discard"])
        app.watchAcceptanceSwipeUp()
        watchAcceptanceExpect(visibleLabels: ["Finish Workout"])
        app.buttons["Finish"].watchAcceptanceTap()
        watchAcceptanceExpect(["watch-summary"], visibleLabels: ["Workout Complete"])
        app.buttons["Finish Workout"].watchAcceptanceTap()
        watchAcceptanceExpect(["watch-summary"], visibleLabels: ["Done"])
        app.watchAcceptanceSwipeUp()
        watchAcceptanceExpect(["watch-home", "watch-empty-workout"], visibleLabels: ["Readiness score"])
        app.buttons["Done"].watchAcceptanceTap()
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["watch-recovery-status"].firstMatch.exists)
    }

    func testPendingHealthSaveKeepsTheWorkoutVisible() throws {
        let app = application(scenario: #function, active: true)
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-demo-active", "--seed-watch-finish-pending"]
        watchAcceptanceExpect(["watch-exercises-page"])
        app.watchAcceptanceLaunch()
        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.52))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12))
        watchAcceptanceExpect(["watch-exercises-page"])
        pageStart.watchAcceptancePress(forDuration: 0.1, thenDragTo: pageEnd)
        watchAcceptanceExpect(["watch-controls-page"], visibleLabels: ["Finish", "Discard"])
        app.watchAcceptanceSwipeUp()
        watchAcceptanceExpect(visibleLabels: ["Finish Workout"])
        app.buttons["Finish"].watchAcceptanceTap()
        watchAcceptanceExpect(["watch-controls-page", "watch-recovery-status"], visibleLabels: ["Finishing workout…"])
        app.buttons["Finish Workout"].watchAcceptanceTap()
        XCTAssertTrue(app.descendants(matching: .any)["watch-active-workout"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["watch-summary"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Finish"].isEnabled)
        XCTAssertFalse(app.buttons["watch-discard-workout"].isEnabled)
        XCTAssertFalse(app.buttons["watch-retry-sync"].exists)
        let banner = app.descendants(matching: .any)["watch-rest-banner"].firstMatch
        let status = app.descendants(matching: .any)["watch-recovery-status"].firstMatch
        XCTAssertTrue(status.isHittable)
        XCTAssertLessThanOrEqual(banner.frame.maxY, status.frame.minY)
    }

    private func application(scenario: String, active: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(app, scenarioID: "WatchRecoveryUITests/\(scenario.replacingOccurrences(of: "()", with: ""))")
        app.launchArguments = ["--seed-watch-demo", "--seed-watch-sync-recovery"]
        if active { app.launchArguments.append("--seed-watch-demo-active") }
        return app
    }
}
