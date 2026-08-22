import XCTest

/// The two lengthened set types, driven the way a lifter reaches them: change
/// the type on a live row, log the work, finish, and read it back in history.
final class LengthenedSetTypeUITests: XCTestCase {
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

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func wait(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    /// Home → empty workout → Machine Chest Press, ending on a live straight
    /// set ready to have its type changed.
    @MainActor
    private func startWorkoutWithChestPress(in app: XCUIApplication) {
        let getStarted = app.buttons["onboarding-get-started"].firstMatch
        if getStarted.waitForExistence(timeout: 1) {
            tapWhenReady(getStarted)
            tapWhenReady(app.buttons["onboarding-setup-continue"].firstMatch)
            tapWhenReady(app.buttons["onboarding-continue-health"].firstMatch)
        }

        let emptyAction = element(app, "start-empty-workout")
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 15))
        tapWhenReady(emptyAction, timeout: 15)

        let replace = app.buttons["Discard Current & Start New"].firstMatch
        if replace.waitForExistence(timeout: 2) { tapWhenReady(replace) }

        let addExercise = element(app, "add-to-workout")
        XCTAssertTrue(addExercise.waitForExistence(timeout: 10))
        tapWhenReady(addExercise)

        let search = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.acceptanceTap()
        search.acceptanceTypeText("Machine Chest")

        let row = element(app, "exercise-row-Machine Chest Press")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.acceptanceTap()

        let commit = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add 1 exercise'")
        ).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        commit.acceptanceTap()
    }

    private func chooseSetType(_ title: String, in app: XCUIApplication) {
        let menu = element(app, "set-type-menu")
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        tapWhenReady(menu)
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "The set-type menu should offer \(title).")
        option.acceptanceTap()
    }

    /// The logger's keyboard covers the lower rows, so each field is
    /// approached with the keyboard already put away — the same thing a lifter
    /// does with the accessory's dismiss control.
    private func dismissKeyboard(in app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss keyboard"].firstMatch
        if dismiss.waitForExistence(timeout: 2), dismiss.isHittable {
            dismiss.acceptanceTap()
        }
        _ = wait(timeout: 5) { app.keyboards.count == 0 }
    }

    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        dismissKeyboard(in: app)
        type(text, into: field)
    }

    private func type(_ text: String, into field: XCUIElement) {
        tapWhenReady(field)
        if let current = field.value as? String, !current.isEmpty, current != "—" {
            field.acceptanceTypeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            )
        }
        field.acceptanceTypeText(text)
    }

    /// An extended set logs its full-range reps in the row and the partials
    /// that followed underneath it, and history keeps the two apart.
    @MainActor
    func testExtendedSetLogsPartialsSeparatelyAndSurvivesToHistory() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.acceptanceLaunch()

        startWorkoutWithChestPress(in: app)

        // A straight set has no partials input — the field belongs to the type
        // that owns it, not to every row.
        XCTAssertFalse(
            element(app, "set-partials-field").exists,
            "A working set should not offer a partials field."
        )

        chooseSetType("Extended set (lengthened)", in: app)
        let badge = element(app, "set-type-menu")
        XCTAssertTrue(
            wait { badge.label.contains("E") },
            "An extended set should carry its own badge; saw \(badge.label)."
        )

        let partials = element(app, "set-partials-field")
        XCTAssertTrue(
            partials.waitForExistence(timeout: 5),
            "Choosing the extended type should reveal the partials field."
        )
        attachScreenshot(app, name: "extended-set-partials-field")

        let weightField = app.textFields.matching(
            NSPredicate(format: "label == %@", "Weight")
        ).firstMatch
        XCTAssertTrue(weightField.waitForExistence(timeout: 5))
        type("60", into: weightField, in: app)

        let repsField = app.textFields.matching(
            NSPredicate(format: "label == %@", "Reps")
        ).firstMatch
        XCTAssertTrue(repsField.waitForExistence(timeout: 5))
        type("8", into: repsField, in: app)
        type("4", into: partials, in: app)

        dismissKeyboard(in: app)
        tapWhenReady(element(app, "complete-set-1"))
        XCTAssertTrue(
            wait { (partials.value as? String) == "4" },
            "The logged partials should survive completion."
        )
        attachScreenshot(app, name: "extended-set-completed")

        // Finish and read the set back from history: the two halves must still
        // be separable there, which is the whole point of the type.
        tapWhenReady(element(app, "finish-workout-button"), timeout: 15)
        let finishAnyway = app.buttons["Finish Anyway"].firstMatch
        if finishAnyway.waitForExistence(timeout: 3) { finishAnyway.acceptanceTap() }
        tapWhenReady(element(app, "save-workout-button"))

        let recentRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home-workout-"))
            .firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 15), "Expected the finished workout in recents.")
        tapWhenReady(recentRow)

        let extendedRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "8 + 4 partials")
        ).firstMatch
        XCTAssertTrue(
            extendedRow.waitForExistence(timeout: 10),
            "History should read the extended set as full-range reps plus partials."
        )
        XCTAssertTrue(
            extendedRow.label.contains("Extended set (lengthened)"),
            "The history row should name the set type it was logged as; saw \(extendedRow.label)."
        )
        attachScreenshot(app, name: "extended-set-in-history")
    }

    /// A lengthened-partials set is all partial-range work: it says so on the
    /// row, and it never grows a partials field of its own.
    @MainActor
    func testLengthenedPartialsSetIsLoggedAndReadAsPartials() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.acceptanceLaunch()

        startWorkoutWithChestPress(in: app)
        chooseSetType("Lengthened partials", in: app)

        let badge = element(app, "set-type-menu")
        XCTAssertTrue(
            wait { badge.label.contains("P") },
            "A lengthened-partials set should carry its own badge; saw \(badge.label)."
        )
        XCTAssertFalse(
            element(app, "set-partials-field").exists,
            "Every rep is already a partial here, so there is no separate partials field."
        )
        attachScreenshot(app, name: "lengthened-partials-row")

        let weightField = app.textFields.matching(
            NSPredicate(format: "label == %@", "Weight")
        ).firstMatch
        XCTAssertTrue(weightField.waitForExistence(timeout: 5))
        type("60", into: weightField, in: app)
        let repsField = app.textFields.matching(
            NSPredicate(format: "label == %@", "Reps")
        ).firstMatch
        type("12", into: repsField, in: app)
        dismissKeyboard(in: app)
        tapWhenReady(element(app, "complete-set-1"))

        tapWhenReady(element(app, "finish-workout-button"), timeout: 15)
        let finishAnyway = app.buttons["Finish Anyway"].firstMatch
        if finishAnyway.waitForExistence(timeout: 3) { finishAnyway.acceptanceTap() }
        tapWhenReady(element(app, "save-workout-button"))

        let recentRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home-workout-"))
            .firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 15))
        tapWhenReady(recentRow)

        let partialRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "12 partials")
        ).firstMatch
        XCTAssertTrue(
            partialRow.waitForExistence(timeout: 10),
            "History should read a lengthened-partials set as partials, not as plain reps."
        )
        XCTAssertTrue(
            partialRow.label.contains("Lengthened partials"),
            "The history row should name the set type it was logged as; saw \(partialRow.label)."
        )
        attachScreenshot(app, name: "lengthened-partials-in-history")
    }

    /// Converting a row away from the extended type takes its partials with
    /// it — a number the athlete can no longer see must not keep counting.
    @MainActor
    func testLeavingTheExtendedTypeClearsItsPartials() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        app.acceptanceLaunch()

        startWorkoutWithChestPress(in: app)
        chooseSetType("Extended set (lengthened)", in: app)

        let partials = element(app, "set-partials-field")
        XCTAssertTrue(partials.waitForExistence(timeout: 5))
        type("4", into: partials, in: app)
        XCTAssertTrue(wait { (partials.value as? String) == "4" })

        chooseSetType("Working", in: app)
        XCTAssertTrue(
            wait { !element(app, "set-partials-field").exists },
            "A working set should not keep the extended type's partials field."
        )

        chooseSetType("Extended set (lengthened)", in: app)
        let reopened = element(app, "set-partials-field")
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        // An empty number field reports its accessibility value, not its text.
        let emptyReadings: Set<String> = ["", "—", "Empty"]
        XCTAssertTrue(
            wait { emptyReadings.contains((reopened.value as? String) ?? "") },
            "Partials from the discarded type must not come back; saw \(reopened.value ?? "nil")."
        )
        attachScreenshot(app, name: "partials-cleared-on-type-change")
    }
}
