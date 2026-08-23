import XCTest

/// A user's own exercise photo and description: written in the exercise form,
/// read back on the exercise, and small enough to recognize an exercise by in
/// search, a routine, and a live workout.
final class ExercisePhotosUITests: XCTestCase {
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

    private func launch(_ app: XCUIApplication, extraArguments: [String] = []) {
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ] + extraArguments
        app.acceptanceLaunch()
    }

    private func openExercisePicker(in app: XCUIApplication) {
        let emptyAction = element(app, "start-empty-workout")
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 15))
        tapWhenReady(emptyAction, timeout: 15)
        let replace = app.buttons["Discard Current & Start New"].firstMatch
        if replace.waitForExistence(timeout: 2) { tapWhenReady(replace) }
        let addExercise = element(app, "add-to-workout")
        XCTAssertTrue(addExercise.waitForExistence(timeout: 10))
        tapWhenReady(addExercise)
    }

    private func search(_ text: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.acceptanceTap()
        field.acceptanceTypeText(text)
    }

    /// One photo is the default, while the optional start/end treatment is a
    /// visible peer choice rather than a requirement hidden in helper copy.
    @MainActor
    func testPhotoEditorMakesSingleAndStartEndChoicesExplicit() throws {
        let app = XCUIApplication()
        launch(app)
        openExercisePicker(in: app)

        acceptanceExpect(
            ["exercise-photo-mode", "add-exercise-photo-single"],
            visibleLabels: ["Single photo", "Start + end"],
            invariants: ["A single photo is visibly supported without requiring a second image."]
        )
        tapWhenReady(element(app, "create-exercise-button"))

        let mode = element(app, "exercise-photo-mode")
        for _ in 0..<5 where !mode.isHittable {
            acceptanceExpect(["exercise-photo-mode"])
            app.acceptanceSwipeUp()
        }
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        XCTAssertTrue(element(app, "add-exercise-photo-single").exists)
        XCTAssertFalse(element(app, "add-exercise-photo-start").exists)
        XCTAssertFalse(element(app, "add-exercise-photo-end").exists)
        XCTAssertTrue(
            app.staticTexts[
                "Start + end animates the movement. Photos stay on this device."
            ].exists
        )
        attachScreenshot(app, name: "exercise-photo-single-mode")

        let startAndEnd = app.buttons["Start + end"].firstMatch
        XCTAssertTrue(startAndEnd.waitForExistence(timeout: 5))
        acceptanceExpect(
            ["add-exercise-photo-start", "add-exercise-photo-end"],
            visibleLabels: ["Start", "End"],
            invariants: ["Start and end are presented as an optional animated treatment."]
        )
        tapWhenReady(startAndEnd)

        XCTAssertTrue(element(app, "add-exercise-photo-start").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "add-exercise-photo-end").exists)
        XCTAssertFalse(element(app, "add-exercise-photo-single").exists)
        attachScreenshot(app, name: "exercise-photo-start-end-mode")
    }

    /// The description is written on the exercise form and read back on the
    /// exercise itself — the same Save/Cancel contract as every other field.
    @MainActor
    func testDescriptionIsWrittenOnTheFormAndReadBackOnTheExercise() throws {
        let app = XCUIApplication()
        launch(app)
        openExercisePicker(in: app)

        tapWhenReady(element(app, "create-exercise-button"))
        let nameField = element(app, "create-exercise-name")
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        tapWhenReady(nameField)
        nameField.acceptanceTypeText("Atlantis Press")

        let description = element(app, "exercise-description")
        XCTAssertTrue(
            description.waitForExistence(timeout: 5),
            "The exercise form should offer a description field."
        )
        // The form is long and the name field left the keyboard up over its
        // lower half; walk down to the field the way the athlete does.
        let dismiss = app.buttons["Dismiss keyboard"].firstMatch
        if dismiss.exists, dismiss.isHittable { dismiss.acceptanceTap() }
        for _ in 0..<6 where !description.isHittable {
            app.acceptanceSwipeUp()
        }
        tapWhenReady(description)
        description.acceptanceTypeText("Seat height 4, handles wide")
        attachScreenshot(app, name: "exercise-form-with-description")

        // Scoped to the sheet's own bar: an unscoped "Create" also matches the
        // picker's "Create exercise" button underneath it.
        let create = app.navigationBars["New Exercise"].buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        tapWhenReady(create)

        // Creating from the picker adds the exercise to the workout and closes
        // the picker, so the new exercise is now a card in the live logger.
        // Its name opens the exercise screen.
        let card = app.buttons.matching(
            NSPredicate(format: "label == 'Atlantis Press'")
        ).firstMatch
        if !card.waitForExistence(timeout: 8) {
            // Creating from inside a workout can leave the logger collapsed to
            // the mini bar; expand it and look again.
            let miniBar = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Workout,'")
            ).firstMatch
            if miniBar.waitForExistence(timeout: 5) { tapWhenReady(miniBar) }
        }
        XCTAssertTrue(
            card.waitForExistence(timeout: 15),
            "The created exercise should be in the workout."
        )
        tapWhenReady(card)

        let shown = element(app, "exercise-user-description")
        XCTAssertTrue(
            shown.waitForExistence(timeout: 10),
            "The exercise should show the description its owner wrote."
        )
        XCTAssertTrue(
            app.staticTexts["Seat height 4, handles wide"].waitForExistence(timeout: 5),
            "The description text itself should be readable on the exercise."
        )
        attachScreenshot(app, name: "exercise-detail-with-description")
    }

    /// The founder's core ask: a photo the athlete added is the picture they
    /// see wherever the exercise appears small — search results and the live
    /// workout card.
    @MainActor
    func testAPhotoRepresentsTheExerciseInSearchAndInAWorkout() throws {
        let app = XCUIApplication()
        launch(app, extraArguments: ["--seed-custom-exercise-media"])
        openExercisePicker(in: app)
        search("Machine Chest", in: app)

        let row = element(app, "exercise-row-Machine Chest Press")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(
            element(app, "exercise-photo-thumbnail").waitForExistence(timeout: 5),
            "A search result should show the athlete's own photo, not the stock illustration."
        )
        attachScreenshot(app, name: "exercise-photo-in-search")

        row.acceptanceTap()
        let commit = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add 1 exercise'")
        ).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        commit.acceptanceTap()

        XCTAssertTrue(
            wait(timeout: 10) { element(app, "exercise-photo-thumbnail").exists },
            "The live workout's exercise card should carry the same photo."
        )
        attachScreenshot(app, name: "exercise-photo-in-live-workout")
    }

    /// The routine is the other place the founder asked for the photo: both
    /// the editor rows you build in and the routine you read back.
    @MainActor
    func testAPhotoRepresentsTheExerciseInARoutine() throws {
        let app = XCUIApplication()
        launch(app, extraArguments: ["--seed-custom-exercise-media"])

        tapWhenReady(element(app, "tab-workout"), timeout: 15)
        tapWhenReady(element(app, "new-routine-button"))

        // Named, because the default "New Routine" collides with the button
        // that creates one — the saved card has to be unambiguously findable.
        let routineName = app.textFields["Routine name"].firstMatch
        XCTAssertTrue(routineName.waitForExistence(timeout: 8))
        tapWhenReady(routineName)
        for _ in 0..<6 {
            guard let current = routineName.value as? String,
                  !current.isEmpty,
                  current != routineName.placeholderValue else { break }
            routineName.acceptanceTypeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            )
        }
        routineName.acceptanceTypeText("Photo Routine")
        let doneKey = app.buttons["Done"].firstMatch
        if doneKey.waitForExistence(timeout: 2), doneKey.isHittable { doneKey.acceptanceTap() }

        tapWhenReady(element(app, "add-to-routine"))
        search("Machine Chest", in: app)
        let row = element(app, "exercise-row-Machine Chest Press")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.acceptanceTap()
        let commit = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Add 1 exercise'")
        ).firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        commit.acceptanceTap()

        XCTAssertTrue(
            element(app, "exercise-photo-thumbnail").waitForExistence(timeout: 10),
            "The routine editor's exercise row should carry the athlete's photo."
        )
        attachScreenshot(app, name: "exercise-photo-in-routine-editor")

        tapWhenReady(element(app, "routine-editor-save-button"))
        let savedRoutine = app.staticTexts["Photo Routine"].firstMatch
        XCTAssertTrue(savedRoutine.waitForExistence(timeout: 10))
        tapWhenReady(savedRoutine)

        // The routine card sets its own accessibility identifier, which
        // overrides the thumbnail's, so the photo is identified by its label
        // on this surface.
        XCTAssertTrue(
            app.images["Your photo"].firstMatch.waitForExistence(timeout: 10),
            "The saved routine should show the same photo."
        )
        attachScreenshot(app, name: "exercise-photo-in-routine-detail")
    }

    /// On the exercise itself the photo is the illustration, at full size and
    /// swipeable, and the description sits with it.
    @MainActor
    func testTheExerciseScreenShowsThePhotoAndDescription() throws {
        let app = XCUIApplication()
        launch(app, extraArguments: ["--seed-custom-exercise-media"])
        openExercisePicker(in: app)
        search("Machine Chest", in: app)

        let details = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'exercise-info-Machine Chest Press'"))
            .firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        tapWhenReady(details)

        let media = element(app, "exercise-user-photos")
        XCTAssertTrue(
            media.waitForExistence(timeout: 10),
            "The exercise screen should lead with the athlete's own photos."
        )
        // Both positions are seeded, so the screen plays through the movement
        // and says so rather than calling itself a stock demonstration.
        XCTAssertTrue(
            media.label.contains("start and end"),
            "A start/end pair should be announced as the athlete's own; saw \(media.label)."
        )
        let playback = element(app, "exercise-photo-playback")
        XCTAssertTrue(
            playback.waitForExistence(timeout: 5),
            "Animation playback should have a visible, accessible control."
        )
        let initialPlaybackLabel = playback.label
        XCTAssertTrue(
            ["Pause photo movement", "Show end position"].contains(initialPlaybackLabel),
            "Playback should either animate normally or offer manual frames under Reduce Motion; saw \(initialPlaybackLabel)."
        )
        playback.acceptanceTap()
        XCTAssertEqual(
            playback.label,
            initialPlaybackLabel == "Show end position" ? "Show start position" : "Play photo movement"
        )
        XCTAssertTrue(
            element(app, "exercise-user-description").waitForExistence(timeout: 5),
            "The description should be readable on the exercise screen."
        )
        attachScreenshot(app, name: "exercise-detail-photo-and-description")
    }
}
