import XCTest

/// Myo-rep activation shortcuts in the live logger: the log button adopts the
/// ghost when nothing is typed (the working-set checkbox contract, one tap
/// for "as planned"), and the activation reps field opens the same hold-drag
/// increment fan as every other numeric field.
///
/// A myo block's ghost comes from the previous SAME-TYPE session
/// (blockTemplate ignores plain-set history), so phase 1 logs a real myo
/// session and phase 2 verifies the shortcuts against it.
final class MyoActivationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapWhenHittable(_ el: XCUIElement, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !el.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        el.tap()
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.label != label && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return element.label == label
    }

    private func replaceNumericText(_ field: XCUIElement, with replacement: String) {
        field.tap()
        XCTAssertTrue(
            XCUIApplication().keyboards.firstMatch.waitForExistence(timeout: 3),
            "Expected the completed activation field to accept keyboard focus."
        )
        // Select the whole numeric token. Its insertion point is not stable
        // after SwiftUI refreshes a completed row, so backspacing from the
        // current caret can otherwise prepend instead of replace.
        field.doubleTap()
        field.typeText(replacement)
        XCTAssertEqual(field.value as? String, replacement)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Bubble → empty workout → add Machine Chest Press → convert set 1 to
    /// Myo-reps. Ends with the activation row on screen.
    @MainActor
    private func startMyoBlock(in app: XCUIApplication) {
        let trigger = app.buttons.matching(identifier: "quick-actions-trigger").firstMatch
        if trigger.waitForExistence(timeout: 4) {
            trigger.tap()
            let emptyAction = app.buttons.matching(identifier: "quick-action-empty").firstMatch
            XCTAssertTrue(emptyAction.waitForExistence(timeout: 3))
            tapWhenHittable(emptyAction)
        } else {
            // A clean install can open directly on the expanded quick-start
            // panel instead of first showing the floating trigger.
            let emptyAction = app.buttons.matching(identifier: "start-empty-workout").firstMatch
            XCTAssertTrue(emptyAction.waitForExistence(timeout: 4))
            for _ in 0..<4 where !emptyAction.isHittable {
                app.swipeUp()
            }
            tapWhenHittable(emptyAction)
        }

        let addExercise = app.buttons["Add Exercise"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()
        let row = element(app, "exercise-row-Machine Chest Press")
        if !row.waitForExistence(timeout: 2) {
            let search = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
            search.tap()
            search.typeText("Machine Chest")
            XCTAssertTrue(row.waitForExistence(timeout: 3), "Expected the exercise in the picker.")
        }
        row.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Add 1 exercise'")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let typeMenu = element(app, "set-type-menu")
        XCTAssertTrue(typeMenu.waitForExistence(timeout: 5))
        typeMenu.tap()
        let myo = app.buttons["Myo-reps"].firstMatch
        XCTAssertTrue(myo.waitForExistence(timeout: 3))
        myo.tap()

        XCTAssertTrue(element(app, "activation-reps-1").waitForExistence(timeout: 3))
    }

    @MainActor
    func testActivationGhostAdoptionAndIncrementFan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg", "-quickActionBubble.v1", ""]
        app.launch()

        // PHASE 1 — log a real myo session so history exists.
        startMyoBlock(in: app)
        let repsField = element(app, "activation-reps-1")
        repsField.tap()
        repsField.typeText("12")
        let activationButton = element(app, "log-activation-1")
        activationButton.tap()
        XCTAssertEqual(activationButton.label, "Activation completed, tap to un-complete",
                       "Expected the activation control to visibly enter its completed state.")
        XCTAssertEqual(activationButton.value as? String, "Completed")
        // Complete the block and save the workout. The checkbox id carries
        // the block's working-set number — match by prefix, first row wins.
        tapWhenHittable(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'complete-set-'")).firstMatch)
        tapWhenHittable(element(app, "finish-workout-button"))
        // The block leaves later working sets unticked, so finishing now
        // raises the unfinished-sets warning. Acknowledging it is the point
        // of this flow, not an obstacle to route around.
        let finishAnyway = app.buttons["Finish Anyway"].firstMatch
        if finishAnyway.waitForExistence(timeout: 3) { finishAnyway.tap() }
        tapWhenHittable(element(app, "save-workout-button"))

        // PHASE 2 — a fresh myo block on the same exercise sees the ghost.
        startMyoBlock(in: app)
        let repsField2 = element(app, "activation-reps-1")
        XCTAssertEqual(repsField2.placeholderValue, "12", "Expected last session's activation reps as the ghost.")

        // One tap on the log button adopts the ghost — no typing. The header
        // summary materializing "12 reps" proves the value landed (an empty
        // field's XCUI `value` echoes the placeholder, so the summary is the
        // honest signal).
        let ghostActivationButton = element(app, "log-activation-1")
        ghostActivationButton.tap()
        XCTAssertEqual(ghostActivationButton.label, "Activation completed, tap to un-complete")
        XCTAssertEqual(ghostActivationButton.value as? String, "Completed")
        XCTAssertTrue(app.staticTexts["12 reps"].waitForExistence(timeout: 3),
                      "Expected the adopted ghost in the block's rep summary.")

        // The activation reps field opens the same hold-drag increment fan as
        // other fields: one +1 band applied to the adopted value.
        let start = repsField2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -50)))
        XCTAssertTrue(app.staticTexts["13 reps"].waitForExistence(timeout: 3),
                      "Expected the +1 fan band applied to the activation reps.")
    }

    /// Regression: the keyboard's activation action previously completed the
    /// enclosing block, which started a 2-minute exercise rest and disabled all
    /// mini-rep controls. It must log only the activation and start micro-rest.
    @MainActor
    func testKeyboardActionLogsActivationWithoutCompletingMyoBlock() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg", "-quickActionBubble.v1", ""]
        app.launch()

        startMyoBlock(in: app)
        let repsField = element(app, "activation-reps-1")
        repsField.tap()
        repsField.typeText("12")

        let logActivation = app.buttons["Log Activation"].firstMatch
        XCTAssertTrue(logActivation.waitForExistence(timeout: 3))
        logActivation.tap()

        let activationButton = element(app, "log-activation-1")
        XCTAssertEqual(activationButton.value as? String, "Completed")

        let completeBlock = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'complete-set-'")
        ).firstMatch
        XCTAssertEqual(
            completeBlock.label,
            "Complete set",
            "Logging the activation must leave the enclosing Myo block open."
        )

        let mini = element(app, "add-mini-1")
        XCTAssertTrue(mini.waitForExistence(timeout: 3))
        XCTAssertTrue(mini.isEnabled, "Mini reps must be usable after activation.")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '0:'")).firstMatch
                .waitForExistence(timeout: 3),
            "Myo activation should start a seconds-scale micro-rest, not a 2-minute exercise rest."
        )
    }

    /// A checked activation remains editable, preserves its values when
    /// unchecked, and can be checked again. Editing a fully logged block must
    /// immediately revise the volume attributed to that completed set.
    @MainActor
    func testCompletedActivationCanBeEditedUncheckedAndRecompleted() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg", "-quickActionBubble.v1", ""]
        app.launch()

        startMyoBlock(in: app)
        let weightField = element(app, "activation-weight")
        let repsField = element(app, "activation-reps-1")
        let activationButton = element(app, "log-activation-1")

        weightField.tap()
        weightField.typeText("50")
        repsField.tap()
        repsField.typeText("12")
        activationButton.tap()
        XCTAssertEqual(activationButton.value as? String, "Completed")

        // Correct the typo while the activation receipt is still checked.
        replaceNumericText(repsField, with: "9")
        XCTAssertTrue(app.staticTexts["9 reps"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            activationButton.value as? String,
            "Completed",
            "Editing a checked activation should update it in place, not discard its receipt."
        )

        if app.buttons["Dismiss keyboard"].firstMatch.exists {
            app.buttons["Dismiss keyboard"].firstMatch.tap()
        }
        activationButton.tap()
        XCTAssertEqual(activationButton.value as? String, "Not completed")
        XCTAssertTrue(
            waitForLabel(activationButton, "Complete activation and start micro-rest"),
            "The activation circle should toggle back to its incomplete state."
        )
        XCTAssertEqual(repsField.value as? String, "9", "Unchecking must preserve the corrected reps.")
        XCTAssertEqual(weightField.value as? String, "50", "Unchecking must preserve the activation weight.")

        activationButton.tap()
        XCTAssertEqual(activationButton.value as? String, "Completed")
        XCTAssertTrue(
            waitForLabel(activationButton, "Activation completed, tap to un-complete"),
            "The same circle should re-complete the activation."
        )
        attachScreenshot(app, name: "Myo activation recompleted with circle control")

        // Complete the whole myo block, then edit the logged activation again.
        tapWhenHittable(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'complete-set-'")).firstMatch
        )
        let volume = element(app, "stat-volume")
        XCTAssertTrue(waitForLabel(volume, "Volume 450 kg", timeout: 5))

        replaceNumericText(repsField, with: "10")
        XCTAssertTrue(
            waitForLabel(volume, "Volume 500 kg", timeout: 5),
            "Changing reps on a completed myo block must recompute its logged volume."
        )
        attachScreenshot(app, name: "Completed Myo activation edited with updated volume")
    }
}
