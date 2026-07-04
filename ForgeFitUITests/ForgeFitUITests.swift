//
//  ForgeFitUITests.swift
//  ForgeFitUITests
//
//  Created by James Pattison on 6/29/26.
//

import XCTest

final class ForgeFitUITests: XCTestCase {

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
    func testRoutineStartLogSetCompleteAndShowsSetupNotes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store"]
        app.launch()

        let startRoutine = app.descendants(matching: .any)["start-routine-Full Body A"]
        if startRoutine.waitForExistence(timeout: 5) {
            startRoutine.tap()
        }

        XCTAssertTrue(app.descendants(matching: .any)["workout-note-banner"].waitForExistence(timeout: 5), "Expected the active workout setup note.")
        XCTAssertTrue(app.staticTexts["Keep shoulder blades pinned before the first rep."].exists, "Expected the seeded machine press cue.")

        let logSetButton = app.descendants(matching: .any)["log-set-button"]
        if !logSetButton.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(logSetButton.waitForExistence(timeout: 3), "Expected Log set button in the active workout.")
        logSetButton.tap()

        let completeButton = app.descendants(matching: .any)["complete-workout-button"]
        if !completeButton.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(completeButton.waitForExistence(timeout: 3), "Expected Complete workout button.")
        completeButton.tap()
        if !app.staticTexts["560 kg total volume"].waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["560 kg total volume"].waitForExistence(timeout: 2), "Expected completed workout volume in recents.")

        app.tabBars.buttons["History"].tap()

        let completedHistoryRow = app.descendants(matching: .any)["history-workout-Full Body A"]
        XCTAssertTrue(completedHistoryRow.waitForExistence(timeout: 5), "Expected completed workout in History.")
        XCTAssertTrue(app.staticTexts["560 kg total volume"].exists, "Expected history summary to show strength volume.")
        completedHistoryRow.tap()
        XCTAssertTrue(app.staticTexts["Machine Chest Press"].waitForExistence(timeout: 5), "Expected exercise detail in workout history.")
        XCTAssertTrue(app.staticTexts["Set 1"].exists, "Expected completed set detail in workout history.")

        app.tabBars.buttons["Routines"].tap()

        app.staticTexts["Full Body A"].tap()
        app.descendants(matching: .any)["routine-exercise-Machine Chest Press"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["routine-note-banner"].waitForExistence(timeout: 5), "Expected the routine setup note.")
        XCTAssertTrue(app.staticTexts["Keep shoulder blades pinned before the first rep."].exists, "Expected the saved setup cue in the routine editor.")
    }

    @MainActor
    func testQuickCardioCanBeSavedToRecents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store"]
        app.launch()

        let startRow = app.descendants(matching: .any)["start-cardio-row"]
        XCTAssertTrue(startRow.waitForExistence(timeout: 5), "Expected Row quick-start.")
        startRow.tap()

        XCTAssertTrue(app.staticTexts["Row details"].waitForExistence(timeout: 5), "Expected structured cardio logger.")

        let saveCardio = app.descendants(matching: .any)["save-cardio-button"]
        if !saveCardio.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(saveCardio.waitForExistence(timeout: 3), "Expected Save cardio button.")
        saveCardio.tap()

        if !app.staticTexts["30 min · 3 km · Effort 7/10"].waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["30 min · 3 km · Effort 7/10"].waitForExistence(timeout: 3), "Expected cardio summary in recents.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
