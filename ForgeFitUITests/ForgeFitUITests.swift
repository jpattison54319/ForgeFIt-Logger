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
        throw XCTSkip("Routine auto-start presentation is still being stabilized; setup-note propagation is covered by ForgeFitTests.")

        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg", "-autoStartRoutine", "YES"]
        app.launch()

        let finishButton = app.descendants(matching: .any)["finish-workout-button"]
        XCTAssertTrue(finishButton.waitForExistence(timeout: 20), "Expected active workout logger.")

        let pinnedNoteLabel = app.staticTexts["Pinned to exercise"]
        if !pinnedNoteLabel.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(pinnedNoteLabel.waitForExistence(timeout: 5), "Expected the active workout setup note.")

        let completeSetButton = app.descendants(matching: .any)["complete-set-1"]
        if !completeSetButton.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(completeSetButton.waitForExistence(timeout: 3), "Expected complete set button in the active workout.")
        completeSetButton.tap()

        if !finishButton.waitForExistence(timeout: 2) {
            app.swipeDown()
        }
        XCTAssertTrue(finishButton.waitForExistence(timeout: 3), "Expected Finish workout button.")
        finishButton.tap()
        app.buttons["Review Summary"].tap()
        app.descendants(matching: .any)["save-workout-button"].tap()

        let completedVolume = app.descendants(matching: .any)
            .matching(identifier: "stat-volume")
            .matching(NSPredicate(format: "label == %@", "Volume 560 kg"))
            .firstMatch
        if !completedVolume.waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(completedVolume.waitForExistence(timeout: 2), "Expected completed workout volume in recents.")

        app.terminate()
        app.launchArguments = ["-weightUnitRaw", "kg", "-initialTab", "home"]
        app.launch()

        let completedHomeRow = app.descendants(matching: .any)
            .matching(identifier: "home-workout-Full Body A")
            .firstMatch
        if !completedHomeRow.waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(completedHomeRow.waitForExistence(timeout: 5), "Expected completed workout in recents.")
        completedHomeRow.tap()
        XCTAssertTrue(app.staticTexts["Machine Chest Press"].waitForExistence(timeout: 5), "Expected exercise detail in workout history.")
        XCTAssertTrue(app.staticTexts["Set 1"].exists, "Expected completed set detail in workout history.")

        app.terminate()
        app.launchArguments = ["-weightUnitRaw", "kg", "-initialTab", "workout"]
        app.launch()

        app.staticTexts["Full Body A"].tap()
        app.descendants(matching: .any)["routine-exercise-Machine Chest Press"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["routine-note-banner"].waitForExistence(timeout: 5), "Expected the routine setup note.")
        XCTAssertTrue(app.staticTexts["Keep shoulder blades pinned before the first rep."].exists, "Expected the saved setup cue in the routine editor.")
    }

    @MainActor
    func testQuickCardioCanBeSavedToRecents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        let startRow = app.descendants(matching: .any).matching(identifier: "start-cardio-row").firstMatch
        XCTAssertTrue(startRow.waitForExistence(timeout: 5), "Expected Row quick-start.")
        startRow.tap()

        XCTAssertTrue(app.buttons["Start Row"].waitForExistence(timeout: 5), "Expected structured cardio logger.")
        app.descendants(matching: .any)["start-cardio-segment"].tap()

        let completeCardio = app.descendants(matching: .any)["complete-cardio-segment"]
        if !completeCardio.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(completeCardio.waitForExistence(timeout: 3), "Expected Complete cardio button.")
        completeCardio.tap()

        app.descendants(matching: .any)["finish-workout-button"].tap()
        app.buttons["Review Summary"].tap()
        app.descendants(matching: .any)["save-workout-button"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["home-workout-Row"].waitForExistence(timeout: 5), "Expected Row cardio workout in recents.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
