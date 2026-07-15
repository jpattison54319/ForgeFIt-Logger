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

    /// Bubble → empty workout → add Machine Chest Press → convert set 1 to
    /// Myo-reps. Ends with the activation row on screen.
    @MainActor
    private func startMyoBlock(in app: XCUIApplication) {
        let trigger = app.buttons.matching(identifier: "quick-actions-trigger").firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 8))
        trigger.tap()
        let emptyAction = app.buttons.matching(identifier: "quick-action-empty").firstMatch
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 3))
        tapWhenHittable(emptyAction)

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
        element(app, "log-activation-1").tap()
        // Complete the block and save the workout. The checkbox id carries
        // the block's working-set number — match by prefix, first row wins.
        tapWhenHittable(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'complete-set-'")).firstMatch)
        tapWhenHittable(element(app, "finish-workout-button"))
        tapWhenHittable(element(app, "save-workout-button"))

        // PHASE 2 — a fresh myo block on the same exercise sees the ghost.
        startMyoBlock(in: app)
        let repsField2 = element(app, "activation-reps-1")
        XCTAssertEqual(repsField2.placeholderValue, "12", "Expected last session's activation reps as the ghost.")

        // One tap on the log button adopts the ghost — no typing. The header
        // summary materializing "12 reps" proves the value landed (an empty
        // field's XCUI `value` echoes the placeholder, so the summary is the
        // honest signal).
        element(app, "log-activation-1").tap()
        XCTAssertTrue(app.staticTexts["12 reps"].waitForExistence(timeout: 3),
                      "Expected the adopted ghost in the block's rep summary.")

        // The activation reps field opens the same hold-drag increment fan as
        // other fields: one +1 band applied to the adopted value.
        let start = repsField2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -50)))
        XCTAssertTrue(app.staticTexts["13 reps"].waitForExistence(timeout: 3),
                      "Expected the +1 fan band applied to the activation reps.")
    }
}
