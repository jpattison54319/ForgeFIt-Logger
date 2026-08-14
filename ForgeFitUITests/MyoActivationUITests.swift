import XCTest

/// The live logger keeps Myo-reps compact until the lifter explicitly starts
/// the set. The focused runner owns activation, mini-sets, micro-rest, resume,
/// finish, and completed-set editing.
final class MyoActivationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapWhenHittable(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(element.isHittable, "Expected \(element) to become hittable.")
        element.tap()
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Home → empty workout → Machine Chest Press → convert the first row to
    /// Myo-reps. Ends on the compact ready card, before the focused runner.
    @MainActor
    private func makeReadyMyoSet(in app: XCUIApplication) {
        let getStarted = app.buttons["Get started"].firstMatch
        if getStarted.waitForExistence(timeout: 1) {
            tapWhenHittable(getStarted)
            tapWhenHittable(app.buttons["Continue"].firstMatch)
            tapWhenHittable(app.buttons["Continue without Health"].firstMatch)
        }

        let emptyAction = element(app, "start-empty-workout")
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 10))
        if !emptyAction.isHittable, !emptyAction.frame.intersects(app.frame) {
            for _ in 0..<3 where !emptyAction.isHittable { app.swipeUp() }
        }
        tapWhenHittable(emptyAction, timeout: 15)

        // `--reset-store` and the app's active-workout restoration can settle
        // in either order on a busy simulator. Resolve the supported prompt so
        // this setup has an explicit post-seed readiness gate before it looks
        // for logger controls.
        let replaceActiveWorkout = app.buttons["Discard Current & Start New"].firstMatch
        if replaceActiveWorkout.waitForExistence(timeout: 2) {
            tapWhenHittable(replaceActiveWorkout)
        }

        let addExercise = element(app, "add-to-workout")
        XCTAssertTrue(addExercise.waitForExistence(timeout: 8))
        tapWhenHittable(addExercise)

        let search = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Tricep push")
        XCTAssertTrue(
            element(app, "exercise-row-Triceps Pushdown").waitForExistence(timeout: 3),
            "Live-workout search should tolerate a missing trailing s in triceps."
        )
        let searchLength = (search.value as? String)?.count ?? 12
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: searchLength))
        search.typeText("Machine Chest")

        let exerciseRow = element(app, "exercise-row-Machine Chest Press")
        XCTAssertTrue(exerciseRow.waitForExistence(timeout: 3))
        exerciseRow.tap()

        let confirm = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add 1 exercise'")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let typeMenu = element(app, "set-type-menu")
        XCTAssertTrue(typeMenu.waitForExistence(timeout: 5))
        typeMenu.tap()
        let myo = app.buttons["Myo-reps"].firstMatch
        XCTAssertTrue(myo.waitForExistence(timeout: 3))
        myo.tap()

        let startMyoSet = element(app, "start-myo-rep-set")
        XCTAssertTrue(
            startMyoSet.waitForExistence(timeout: 5),
            "Myo-reps should render as a compact launch card in the workout."
        )
        XCTAssertLessThan(
            startMyoSet.frame.width,
            app.frame.width * 0.75,
            "The inline launcher should remain a compact action, not a full-width workout control."
        )
        XCTAssertFalse(
            element(app, "myo-activation-reps-1").exists,
            "Activation controls belong in the focused runner, not the workout list."
        )
        XCTAssertFalse(
            app.staticTexts["ACTIVATION SUGGESTION"].exists,
            "The inline launcher should not repeat its prefilled values as a suggestion."
        )
    }

    @MainActor
    func testFocusedMyoFlowLogsFinishesAndEdits() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        makeReadyMyoSet(in: app)
        tapWhenHittable(element(app, "start-myo-rep-set"))

        XCTAssertTrue(app.staticTexts["Myo-rep Set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Set 1"].exists)
        XCTAssertFalse(app.staticTexts["Set 0"].exists)
        XCTAssertTrue(element(app, "myo-activation-weight").exists)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Suggested ·'")).firstMatch.exists,
            "The focused runner should present prefilled values only in its input controls."
        )
        let activationRepsField = element(app, "myo-activation-reps-1")
        XCTAssertTrue(activationRepsField.exists)
        XCTAssertTrue(
            element(app, "guided-myo-live-heart-rate").exists,
            "The focused Myo-rep runner should keep live heart rate visible beside the rest duration."
        )

        let increaseActivationReps = app.buttons["Increase Activation reps"].firstMatch
        for _ in 0..<3 { tapWhenHittable(increaseActivationReps) }
        XCTAssertEqual(activationRepsField.value as? String, "4")

        let fanStart = activationRepsField.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        fanStart.press(
            forDuration: 0.55,
            thenDragTo: fanStart.withOffset(CGVector(dx: 0, dy: 64)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        XCTAssertEqual(
            activationRepsField.value as? String,
            "3",
            "Dragging down to the guided Myo-rep fan's nearest band should decrement reps."
        )
        let decreaseActivationReps = app.buttons["Decrease Activation reps"].firstMatch
        tapWhenHittable(decreaseActivationReps)
        tapWhenHittable(decreaseActivationReps)
        XCTAssertEqual(activationRepsField.value as? String, "1")

        activationRepsField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.7)
        XCTAssertFalse(
            app.keyboards.firstMatch.exists,
            "A Myo-rep field hold should keep the quick-increment gesture instead of opening the keyboard."
        )
        XCTAssertFalse(
            element(app, "quick-increment-option-0").exists,
            "Releasing without choosing an increment should close the fan."
        )

        tapWhenHittable(activationRepsField)
        let dismissKeyboard = app.buttons["Dismiss keyboard"].firstMatch
        XCTAssertTrue(
            dismissKeyboard.waitForExistence(timeout: 3),
            "The focused Myo runner should keep the app-owned keyboard accessory."
        )
        tapWhenHittable(dismissKeyboard)
        XCTAssertTrue(
            app.keyboards.firstMatch.waitForNonExistence(timeout: 3),
            "The custom keyboard action should return the full Myo controls."
        )

        tapWhenHittable(element(app, "myo-log-activation-1"))
        XCTAssertTrue(element(app, "myo-mini-reps-1").waitForExistence(timeout: 3))
        XCTAssertTrue(
            element(app, "myo-skip-rest").waitForExistence(timeout: 3),
            "Logging activation should start the set-scoped micro-rest."
        )
        XCTAssertLessThan(
            element(app, "myo-skip-rest").frame.width,
            app.frame.width * 0.65,
            "Skip Rest should be a compact timer action."
        )
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Suggested ·'")).firstMatch.exists,
            "A logged activation should show only what was performed."
        )

        tapWhenHittable(element(app, "myo-log-mini-1"))
        let loggedMini = element(app, "myo-edit-mini-1-1")
        XCTAssertTrue(loggedMini.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "Polished active Myo-rep set")
        tapWhenHittable(loggedMini)
        XCTAssertTrue(app.staticTexts["Edit Mini-set 1"].waitForExistence(timeout: 3))
        XCTAssertTrue(element(app, "save-myo-mini-edits").exists)
        tapWhenHittable(app.buttons["Cancel mini-set edits"].firstMatch)
        tapWhenHittable(element(app, "finish-myo-rep-set"))

        let edit = element(app, "edit-myo-rep-set")
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        let completedCard = element(app, "myo-rep-set-card")
        XCTAssertEqual(completedCard.label, "Completed Myo-rep set")
        XCTAssertFalse(
            app.staticTexts["Myo-rep set complete"].exists,
            "Completion belongs to the parent set checkmark, not a nested completion card."
        )
        XCTAssertTrue(app.staticTexts["1 + 1"].exists)
        attachScreenshot(app, name: "Completed dedicated Myo-rep set")

        tapWhenHittable(edit)
        XCTAssertTrue(app.staticTexts["Edit Myo-rep Set"].waitForExistence(timeout: 5))
        let activationReps = element(app, "edit-myo-activation-reps-1")
        XCTAssertTrue(activationReps.exists)
        tapWhenHittable(app.buttons["Increase Activation reps"].firstMatch)
        tapWhenHittable(element(app, "save-myo-rep-edits"))

        XCTAssertTrue(element(app, "edit-myo-rep-set").waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["2 + 1"].waitForExistence(timeout: 3),
            "The completed card should immediately reflect edited activation and mini-set reps."
        )
    }

    @MainActor
    func testDismissedMyoProgressResumesWithoutCompleting() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        makeReadyMyoSet(in: app)
        tapWhenHittable(element(app, "start-myo-rep-set"))
        tapWhenHittable(element(app, "myo-log-activation-1"))

        let returnToWorkout = app.buttons[
            "Save Myo-rep progress and return to workout"
        ].firstMatch
        XCTAssertTrue(returnToWorkout.waitForExistence(timeout: 3))
        tapWhenHittable(returnToWorkout)

        let resume = element(app, "resume-myo-rep-set")
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Myo-rep set in progress"].exists)
        XCTAssertFalse(element(app, "edit-myo-rep-set").exists)

        tapWhenHittable(resume)
        XCTAssertTrue(app.staticTexts["Activation logged"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "myo-mini-reps-1").exists)
        XCTAssertTrue(element(app, "finish-myo-rep-set").isEnabled)
        attachScreenshot(app, name: "Resumed dedicated Myo-rep set")
    }
}
