import XCTest

/// Covers the learnability-critical handoff between "Save Workout" and the
/// optional decision to carry live structural changes into future workouts.
final class RoutineUpdateSheetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testChangedWorkoutExplainsBothSaveOutcomes() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--skip-onboarding",
            "--auto-start-routine",
            "-weightUnitRaw", "kg",
        ]
        acceptanceExpect(
            ["add-set-button", "finish-workout-button"],
            phase: .setup,
            invariants: ["A deterministic routine opens in the live logger with explicit workout controls."]
        )
        app.acceptanceLaunch()

        let addSet = app.buttons["add-set-button"].firstMatch
        XCTAssertTrue(addSet.waitForExistence(timeout: 15), "Expected the auto-started routine.")
        acceptanceExpect(
            ["add-set-button", "finish-workout-button"],
            invariants: ["Adding a set keeps the live logger controls available while changing workout structure."]
        )
        tapWhenReady(addSet)

        acceptanceExpect(
            visibleLabels: ["Finish Anyway"],
            invariants: ["Finishing with the added set incomplete presents an explicit finish decision."]
        )
        tapWhenReady(app.buttons["finish-workout-button"].firstMatch)
        let finishAnyway = app.buttons["Finish Anyway"].firstMatch
        try acceptanceRequire(
            finishAnyway.waitForExistence(timeout: 3),
            "Expected the unfinished-set decision before the post-workout summary."
        )
        acceptanceExpect(
            ["save-workout-button"],
            visibleLabels: ["Workout complete"],
            invariants: ["Choosing to finish anyway reaches the post-workout save summary."]
        )
        tapWhenReady(finishAnyway)

        acceptanceExpect(
            ["update-routine-and-save-workout-button", "save-workout-only-button"],
            visibleLabels: ["Update saved routine?", "1 set added"],
            invariants: ["The save decision explains that routine structure changes affect future workouts."]
        )
        tapWhenReady(app.buttons["save-workout-button"].firstMatch)

        XCTAssertTrue(app.staticTexts["Update saved routine?"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Would you like to apply them")
            ).firstMatch.exists,
            "Expected the sheet to explain that the routine change affects next time."
        )
        XCTAssertTrue(app.staticTexts["1 set added"].exists)

        let updateAndSave = app.buttons["update-routine-and-save-workout-button"].firstMatch
        let saveOnly = app.buttons["save-workout-only-button"].firstMatch
        XCTAssertTrue(updateAndSave.exists && updateAndSave.isHittable)
        XCTAssertTrue(saveOnly.exists && saveOnly.isHittable)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Routine update decision sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        acceptanceExpect(
            ["quick-action-cardio-run", "quick-action-bodyweight", "quick-action-empty"],
            invariants: ["Save Workout Only completes the workout without applying changes to the saved routine."]
        )
        tapWhenReady(saveOnly)
        XCTAssertFalse(
            saveOnly.waitForExistence(timeout: 8),
            "Save Workout Only should complete the decision and dismiss the finish flow."
        )
        XCTAssertFalse(
            app.buttons["save-workout-button"].firstMatch.exists,
            "The post-workout summary should close after the workout saves."
        )
    }

    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(element.exists && element.isHittable, "Expected a hittable \(element).")
        element.acceptanceTap()
    }
}
