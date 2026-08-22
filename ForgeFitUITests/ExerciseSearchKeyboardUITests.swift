import XCTest

/// The exercise picker's search field lives in the navigation bar drawer,
/// where the system offers no way to put the keyboard away. It gets the live
/// logger's dismiss control, and any drag on the results does the same thing.
final class ExerciseSearchKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !element.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(element.isHittable, "Expected \(element) to become hittable.")
        element.acceptanceTap()
    }

    @discardableResult
    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opens the picker from a live empty workout and starts a search.
    @MainActor
    private func openSearchingPicker(in app: XCUIApplication) -> XCUIElement {
        let emptyAction = element(app, "start-empty-workout")
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 15))
        tapWhenReady(emptyAction, timeout: 15)

        let replace = app.buttons["Discard Current & Start New"].firstMatch
        if replace.waitForExistence(timeout: 2) { tapWhenReady(replace) }

        let addExercise = element(app, "add-to-workout")
        XCTAssertTrue(addExercise.waitForExistence(timeout: 10))
        tapWhenReady(addExercise)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.acceptanceTap()
        search.acceptanceTypeText("press")
        return search
    }

    @MainActor
    func testSearchKeyboardHasADismissControl() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.acceptanceLaunch()

        _ = openSearchingPicker(in: app)

        let dismiss = element(app, "exercise-search-dismiss-keyboard")
        XCTAssertTrue(
            dismiss.waitForExistence(timeout: 5),
            "Searching should offer the same keyboard-dismiss control the logger does."
        )
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44, "The dismiss control needs a real tap target.")
        attachScreenshot(app, name: "exercise-search-keyboard-accessory")

        tapWhenReady(dismiss)
        XCTAssertTrue(
            wait(timeout: 8) { app.keyboards.count == 0 },
            "Tapping the dismiss control should put the keyboard away."
        )
        XCTAssertTrue(
            wait(timeout: 5) { !dismiss.exists },
            "The accessory belongs to the keyboard and should leave with it."
        )
        // The typed query survives — dismissing the keyboard is not a reset.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'"))
                .firstMatch.waitForExistence(timeout: 5),
            "The search results should still be on screen after the keyboard closes."
        )
        attachScreenshot(app, name: "exercise-search-keyboard-dismissed")
    }

    @MainActor
    func testScrollingTheResultsDismissesTheKeyboard() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.acceptanceLaunch()

        _ = openSearchingPicker(in: app)
        XCTAssertTrue(
            wait(timeout: 8) { app.keyboards.count > 0 },
            "Tapping the search field should raise the keyboard."
        )

        let firstRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'"))
            .firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8), "Expected search results to scroll.")
        app.acceptanceSwipeUp()

        XCTAssertTrue(
            wait(timeout: 8) { app.keyboards.count == 0 },
            "Scrolling the exercise list should dismiss the keyboard."
        )
        attachScreenshot(app, name: "exercise-search-scroll-dismissed-keyboard")
    }
}
