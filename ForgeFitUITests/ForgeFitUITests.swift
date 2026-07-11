//
//  ForgeFitUITests.swift
//  ForgeFitUITests
//
//  Created by James Pattison on 6/29/26.
//

import XCTest

final class ForgeFitUITests: XCTestCase {

    override func setUpWithError() throws {
        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // The simulator's device orientation persists across runs, and a sim
        // left in landscape broke two picker tests for weeks: sheets + the
        // keyboard squeezed the 402pt-tall landscape viewport until row taps
        // resolved to degenerate coordinates (the failure video showed taps
        // landing inside the keyboard). The app is portrait-locked on iPhone
        // now, but pin the device too so tests never depend on leftover
        // simulator state.
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    // MARK: - Shared helpers

    /// Sheet-dismiss and view-transition animations can leave an element
    /// existing but briefly un-hittable (e.g. a button appearing where a
    /// different one was a moment ago as the view swaps branches). Poll
    /// instead of assuming the first frame after `waitForExistence` is
    /// already interactive.
    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        element.tap()
    }

    /// Scrolls `element` into view when it's off the initial viewport in
    /// either axis — e.g. Home's quick-start row is a horizontal ScrollView
    /// nested inside the screen's vertical one, and XCUITest's built-in
    /// single-pass "scroll to visible" doesn't reliably resolve nested
    /// scroll axes (it can report a degenerate {-1,-1} hit point and fail).
    /// Tries vertical first (content above quick-start varies: the readiness
    /// card / "Jump back in" suggestion only render once there's data), then
    /// horizontal (quick-start tile order is user-customizable and persists
    /// in UserDefaults across `--reset-store`, which only clears SwiftData).
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxAttemptsPerAxis: Int = 6) {
        var attempts = 0
        while !(element.exists && element.isHittable), attempts < maxAttemptsPerAxis {
            app.swipeUp(velocity: .fast)
            attempts += 1
        }
        attempts = 0
        while !(element.exists && element.isHittable), attempts < maxAttemptsPerAxis {
            app.swipeLeft(velocity: .fast)
            attempts += 1
        }
    }

    @MainActor
    func testRoutineStartLogSetCompleteAndShowsSetupNotes() throws {
        throw XCTSkip("Routine auto-start presentation is still being stabilized; setup-note propagation is covered by ForgeFitTests.")
    }

    @MainActor
    func testQuickCardioCanBeSavedToRecents() throws {
        let app = XCUIApplication()
        // --reset-store only wipes SwiftData (AccountResetService); it does not
        // touch UserDefaults. Home's quick-start tile order is user-customizable
        // and persisted there (homeQuickStartActions.v1), so a prior manual
        // session on this simulator could leave "Row" anywhere in the row —
        // force the built-in default order [Run, Cycle, Row, Walk] so the tile
        // is always in the same place.
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg", "-homeQuickStartActions.v1", ""]
        app.launch()

        let startRow = app.descendants(matching: .any).matching(identifier: "start-cardio-row").firstMatch
        XCTAssertTrue(startRow.waitForExistence(timeout: 5), "Expected Row quick-start.")
        // Nested horizontal-in-vertical ScrollViews: XCUITest's single-pass
        // auto-scroll can fail to resolve both axes (surfaced as a degenerate
        // {-1,-1} hit point) depending on what renders above quick-start
        // (readiness card, "Jump back in" suggestion). Scroll explicitly first.
        scrollUntilHittable(startRow, in: app)
        XCTAssertTrue(startRow.isHittable, "Expected the Row quick-start tile to be reachable by scrolling.")
        startRow.tap()

        XCTAssertTrue(app.buttons["Start Row"].waitForExistence(timeout: 5), "Expected structured cardio logger.")
        tapWhenReady(app.descendants(matching: .any)["start-cardio-segment"])

        // notStarted → inProgress swaps the whole card body; the Complete
        // button that appears in its place can be briefly un-hittable mid
        // transition.
        let completeCardio = app.descendants(matching: .any)["complete-cardio-segment"]
        if !completeCardio.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(completeCardio.waitForExistence(timeout: 3), "Expected Complete cardio button.")
        tapWhenReady(completeCardio)

        // Finish opens the review summary directly (no intermediate
        // "Finish this workout?" dialog).
        app.descendants(matching: .any)["finish-workout-button"].tap()
        app.descendants(matching: .any)["save-workout-button"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["home-workout-Row"].waitForExistence(timeout: 5), "Expected Row cardio workout in recents.")
    }

    /// Regression: typing in the exercise picker's search crashed the app when
    /// the library contained duplicate exercise IDs (CloudKit can't enforce
    /// unique constraints, so a sync/re-seed race produces them). Drives the
    /// exact reported flow — edit a routine, add an exercise, search — and
    /// asserts the app stays alive with results rendering.
    @MainActor
    func testExerciseSearchDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        app.descendants(matching: .any)["tab-workout"].firstMatch.tap()

        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5), "Expected New Routine button.")
        newRoutine.tap()

        let addExercise = app.buttons["Add Exercise"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5), "Expected Add Exercise in the routine editor.")
        addExercise.tap()

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Expected the exercise search field.")
        searchField.tap()
        searchField.typeText("bench press")

        // The crash fired on the first keystroke — surviving typing plus a
        // rendered ranked result (or the no-matches empty state) is the pass.
        XCTAssertEqual(app.state, .runningForeground, "App should survive exercise search.")
        let benchRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'bench'")
        ).firstMatch
        let hasResults = benchRow.waitForExistence(timeout: 3)
            || app.staticTexts["No matches"].waitForExistence(timeout: 2)
        XCTAssertTrue(hasResults, "Search should render results or the empty state, not crash.")

        // Fuzzy path (typo → Levenshtein branch) while we're here.
        searchField.typeText(XCUIKeyboardKey.delete.rawValue)
        searchField.typeText("presz")
        XCTAssertEqual(app.state, .runningForeground, "App should survive fuzzy search.")

        // Create-from-search: the escape hatch under the results opens the
        // create form with the searched name prefilled — and no duplicate
        // suggestions (the search already established it doesn't exist).
        let createFromSearch = app.descendants(matching: .any)["create-from-search"].firstMatch
        var scrollAttempts = 0
        while !(createFromSearch.exists && createFromSearch.isHittable), scrollAttempts < 6 {
            app.swipeUp(velocity: .fast)
            scrollAttempts += 1
        }
        XCTAssertTrue(createFromSearch.waitForExistence(timeout: 3), "Expected the create-from-search button under results.")
        createFromSearch.tap()

        let nameField = app.textFields["create-exercise-name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Expected the create form.")
        let prefilled = nameField.value as? String ?? ""
        XCTAssertFalse(prefilled.isEmpty, "Expected the searched name prefilled.")
        XCTAssertTrue(prefilled.lowercased().contains("bench"), "Prefill should carry the searched text, got \(prefilled).")
        let suggestion = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'use-existing-'")
        ).firstMatch
        XCTAssertFalse(suggestion.waitForExistence(timeout: 1), "Duplicate suggestions should be off for the search-origin path.")
    }

    /// Creating an exercise whose name matches an existing one surfaces a
    /// "use this instead" suggestion; tapping it adds the existing exercise to
    /// the routine and abandons creation (no duplicate is made).
    @MainActor
    func testCreateExerciseSuggestsExistingDuplicate() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        app.descendants(matching: .any)["tab-workout"].firstMatch.tap()
        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5))
        newRoutine.tap()
        let addExercise = app.buttons["Add Exercise"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        addExercise.tap()

        // Open the create form from the picker toolbar.
        let createButton = app.descendants(matching: .any)["create-exercise-button"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.tap()

        let nameField = app.textFields["create-exercise-name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Expected the name field.")
        nameField.tap()
        nameField.typeText("bench press")   // lowercase on purpose — casing-tolerant

        let suggestion = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'use-existing-'")
        ).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 4), "Expected a duplicate suggestion for an existing exercise.")
        suggestion.tap()

        // Creation abandoned, existing exercise landed in the routine editor.
        XCTAssertTrue(app.buttons["Add Exercise"].firstMatch.waitForExistence(timeout: 5), "Expected to be back in the routine editor.")
        let inRoutine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'bench press'")).firstMatch
        XCTAssertTrue(inRoutine.waitForExistence(timeout: 3), "Expected the existing exercise in the routine.")
    }

    /// Yoga flow building: users can inspect a pose, go back to the picker,
    /// keep selecting poses, and save the configured Yoga Session.
    @MainActor
    func testYogaPoseDetailCanReturnToPosePickerAndContinueAdding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        app.descendants(matching: .any)["tab-workout"].firstMatch.tap()
        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5))
        newRoutine.tap()

        let addExercise = app.buttons["Add Exercise"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        tapWhenReady(addExercise)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Yoga Session")

        let yogaSession = app.descendants(matching: .any)["exercise-row-Yoga Session"].firstMatch
        XCTAssertTrue(yogaSession.waitForExistence(timeout: 5), "Expected the Yoga Session exercise row.")
        tapWhenReady(yogaSession)
        let commitSession = app.buttons["Add 1 exercise"].firstMatch
        XCTAssertTrue(commitSession.waitForExistence(timeout: 3))
        tapWhenReady(commitSession)

        let flowBuilder = app.descendants(matching: .any)["routine-yoga-flow-builder"].firstMatch
        XCTAssertTrue(flowBuilder.waitForExistence(timeout: 5), "Expected the Yoga Session flow builder entry.")
        tapWhenReady(flowBuilder)

        let addPose = app.descendants(matching: .any)["add-pose-to-flow"].firstMatch
        XCTAssertTrue(addPose.waitForExistence(timeout: 5), "Expected Add Pose in the yoga flow builder.")
        tapWhenReady(addPose)

        let poseSearch = app.searchFields.firstMatch
        XCTAssertTrue(poseSearch.waitForExistence(timeout: 5), "Expected pose picker search.")
        poseSearch.tap()
        poseSearch.typeText("Pigeon Pose")

        let info = app.descendants(matching: .any)["exercise-info-Pigeon Pose"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "Expected a pose details button.")
        tapWhenReady(info)

        let detailTitle = app.descendants(matching: .any)["exercise-detail-title-Pigeon Pose"].firstMatch
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 5), "Expected Pigeon Pose detail.")
        let back = app.descendants(matching: .any)["exercise-detail-back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Expected detail back button.")
        tapWhenReady(back)

        let poseRow = app.descendants(matching: .any)["exercise-row-Pigeon Pose"].firstMatch
        XCTAssertTrue(poseRow.waitForExistence(timeout: 5), "Expected to return to the pose picker after closing detail.")
        tapWhenReady(poseRow)
        let commitPose = app.buttons["Add 1 exercise"].firstMatch
        XCTAssertTrue(commitPose.waitForExistence(timeout: 3), "Expected to continue selecting poses after detail.")
        tapWhenReady(commitPose)

        XCTAssertTrue(app.staticTexts["Pigeon Pose"].waitForExistence(timeout: 5), "Expected selected pose in the flow builder.")
        app.buttons["Save"].firstMatch.tap()

        XCTAssertTrue(flowBuilder.waitForExistence(timeout: 5), "Expected to return to the routine editor after saving the flow.")
        let configured = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '1 pose'")).firstMatch
        XCTAssertTrue(configured.waitForExistence(timeout: 3), "Expected the Yoga Session row to show the saved pose flow.")
    }

    /// Routine editor: exercises can be reordered (mirrors the live logger's
    /// reorder mode) and replaced in place (via the row's ellipsis menu),
    /// without changing how many exercises the routine has.
    @MainActor
    func testRoutineEditorReordersAndReplacesExercises() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        app.descendants(matching: .any)["tab-workout"].firstMatch.tap()
        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5))
        newRoutine.tap()

        func addExercise(searching term: String) {
            let addExercise = app.buttons["Add Exercise"].firstMatch
            XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
            tapWhenReady(addExercise)
            let searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 5))
            searchField.tap()
            searchField.typeText(term)
            let row = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")
            ).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 4), "Expected a search result for '\(term)'.")
            row.tap()
            // This picker allows multi-select — tapping a row only checks it;
            // committing (and dismissing) needs the bottom "Add 1 exercise" button.
            let commit = app.buttons["Add 1 exercise"].firstMatch
            XCTAssertTrue(commit.waitForExistence(timeout: 3), "Expected the commit button after selecting a result.")
            tapWhenReady(commit)
        }

        addExercise(searching: "squat")
        addExercise(searching: "curl")

        let menus = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'routine-exercise-menu-'")
        )
        XCTAssertEqual(menus.count, 2, "Expected two exercises in the routine before reordering.")

        // Reorder mode: only offered once there's something to reorder.
        let reorderButton = app.buttons["reorder-exercises-button"].firstMatch
        XCTAssertTrue(reorderButton.waitForExistence(timeout: 5), "Expected the Reorder button with 2+ exercises.")
        tapWhenReady(reorderButton)
        XCTAssertTrue(app.staticTexts["Reorder"].waitForExistence(timeout: 3), "Expected the Reorder screen.")
        let reorderDone = app.buttons["reorder-done-button"].firstMatch
        XCTAssertTrue(reorderDone.waitForExistence(timeout: 3))
        tapWhenReady(reorderDone)
        XCTAssertTrue(app.buttons["Add Exercise"].firstMatch.waitForExistence(timeout: 5), "Expected to return to normal editing after Done.")

        // Replace: swap one exercise for another without changing the count.
        let firstMenu = menus.firstMatch
        XCTAssertTrue(firstMenu.waitForExistence(timeout: 5))
        tapWhenReady(firstMenu)
        let replaceItem = app.buttons["Replace Exercise"].firstMatch
        XCTAssertTrue(replaceItem.waitForExistence(timeout: 3))
        replaceItem.tap()

        let replaceSearch = app.searchFields.firstMatch
        XCTAssertTrue(replaceSearch.waitForExistence(timeout: 5), "Expected the replace picker's search field.")
        replaceSearch.tap()
        replaceSearch.typeText("press")
        let replacementRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")
        ).firstMatch
        XCTAssertTrue(replacementRow.waitForExistence(timeout: 4))
        replacementRow.tap()

        XCTAssertTrue(app.buttons["Add Exercise"].firstMatch.waitForExistence(timeout: 5), "Expected to be back in the routine editor after replacing.")
        let menusAfterReplace = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'routine-exercise-menu-'")
        )
        XCTAssertEqual(menusAfterReplace.count, 2, "Replacing should swap the exercise, not add or remove one.")
    }

    /// Regression: the keyboard accessory's Complete button used to stop
    /// rendering after the accessory's own dismiss chevron was used (the old
    /// UIKit toolbar was reused blank on refocus). Drives the reported flow —
    /// focus a set input, dismiss via the accessory, refocus — and asserts
    /// the accessory comes back intact every time.
    @MainActor
    func testKeyboardAccessorySurvivesDismissAndRefocus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--auto-start-routine", "-weightUnitRaw", "kg"]
        app.launch()

        let weightField = app.textFields["Weight"].firstMatch
        XCTAssertTrue(weightField.waitForExistence(timeout: 10), "Expected the live logger with a weight field.")
        tapWhenReady(weightField)

        let complete = app.buttons["Complete"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "Expected the Complete accessory above the keyboard.")

        let dismissKeyboard = app.buttons["Dismiss keyboard"].firstMatch
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3), "Expected the dismiss chevron in the accessory.")
        dismissKeyboard.tap()

        // The dismissed keyboard takes its accessory with it.
        let deadline = Date().addingTimeInterval(3)
        while complete.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }

        // Refocus: the accessory must render again — this is where the old
        // UIKit-toolbar approach came back blank.
        tapWhenReady(weightField)
        XCTAssertTrue(complete.waitForExistence(timeout: 5), "Accessory should render again after dismiss + refocus.")
        XCTAssertTrue(app.buttons["Next"].firstMatch.exists, "Weight field should offer Next to advance to reps.")
    }

    /// The rest countdown bar's controls must respond — the old header pill
    /// recreated its buttons inside a half-second TimelineView, which dropped
    /// in-flight taps (reported as "skip / +/− don't work"). Completing a set
    /// auto-starts rest; skipping it must actually clear the bar.
    @MainActor
    func testRestTimerBarAppearsAndSkipWorks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--auto-start-routine", "-weightUnitRaw", "kg"]
        app.launch()

        let completeSet = app.buttons["complete-set-1"].firstMatch
        XCTAssertTrue(completeSet.waitForExistence(timeout: 10), "Expected the live logger with a completable set.")
        tapWhenReady(completeSet)

        let skip = app.buttons["skip-rest-timer"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 5), "Completing a set should start rest and show the countdown bar.")
        tapWhenReady(skip)

        let deadline = Date().addingTimeInterval(3)
        while skip.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(skip.exists, "Skip should stop the rest timer and remove the bar.")
    }

    /// Wrapped acceptance: the Home "Report Available" card shows for a
    /// fresh report, opening it presents the story, and after closing, the
    /// card is gone (viewed) — while the report stays reachable in Profile.
    @MainActor
    func testWrappedCardOpensStoryThenDisappearsFromHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-wrapped-demo", "-weightUnitRaw", "kg", "-didOnboard", "YES"]
        app.launch()

        let card = app.descendants(matching: .any)["wrapped-report-available"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Expected the Monthly Report Available card on Home.")
        // The card renders below the week card without scrolling. Coordinate
        // tap because XCUITest never resolves this Card-labeled Button as
        // hittable (and scrolling to chase hittability lands taps on the
        // wrong card).
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Story is up: page through a few pages via the right tap zone.
        let close = app.buttons["Close report"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Expected the Wrapped story to present.")
        let shareButton = app.buttons["Share this page"].firstMatch
        XCTAssertTrue(shareButton.exists, "Every page should carry a share button.")
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        tapWhenReady(close)

        // Opening counted as viewed: the Home card is gone.
        let deadline = Date().addingTimeInterval(4)
        while card.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(card.exists, "The Home card must disappear once the report is viewed.")
    }

    // MARK: - Coach's Corner (Phase 5)

    /// Home's Coach's Corner entry point is a `CircleIconButton` with an
    /// explicit `accessibilityLabel` (it renders icon-only, so VoiceOver
    /// coverage depends on that label) — tapping it must present the Corner
    /// sheet.
    @MainActor
    func testCoachButtonOpensCoachsCornerSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        let coachButton = app.buttons["Coach's Corner"].firstMatch
        XCTAssertTrue(coachButton.waitForExistence(timeout: 5), "Expected the accessible Coach's Corner button on Home.")
        tapWhenReady(coachButton)

        XCTAssertTrue(app.navigationBars["Coach's Corner"].waitForExistence(timeout: 5), "Expected the Coach's Corner sheet to present.")
    }

    /// A fresh account (no coached program yet) must offer "Build my plan"
    /// in the "This week" section rather than a dangling active-program card.
    @MainActor
    func testCoachCornerNoPlanStateShowsBuildMyPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        let coachButton = app.buttons["Coach's Corner"].firstMatch
        XCTAssertTrue(coachButton.waitForExistence(timeout: 5))
        tapWhenReady(coachButton)
        XCTAssertTrue(app.navigationBars["Coach's Corner"].waitForExistence(timeout: 5))

        let buildPlan = app.descendants(matching: .any)["coach-corner-build-plan"].firstMatch
        scrollUntilHittable(buildPlan, in: app)
        XCTAssertTrue(buildPlan.waitForExistence(timeout: 5), "Expected 'Build my plan' with no active coached program.")
    }

    /// Coach's Corner's top-level sections carry stable VoiceOver
    /// identifiers on their headers, so an accessibility audit (or a future
    /// test) can locate each section without relying on visible text.
    @MainActor
    func testCoachCornerSectionsHaveVoiceOverIdentifiers() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        let coachButton = app.buttons["Coach's Corner"].firstMatch
        XCTAssertTrue(coachButton.waitForExistence(timeout: 5))
        tapWhenReady(coachButton)
        XCTAssertTrue(app.navigationBars["Coach's Corner"].waitForExistence(timeout: 5))

        let todaysCall = app.descendants(matching: .any)["coach-corner-section-todays-call"].firstMatch
        XCTAssertTrue(todaysCall.waitForExistence(timeout: 5), "Expected the Today's call section identifier.")

        let thisWeek = app.descendants(matching: .any)["coach-corner-section-this-week"].firstMatch
        scrollUntilHittable(thisWeek, in: app)
        XCTAssertTrue(thisWeek.waitForExistence(timeout: 5), "Expected the This week section identifier.")

        let askCoach = app.descendants(matching: .any)["coach-corner-section-ask-coach"].firstMatch
        scrollUntilHittable(askCoach, in: app)
        XCTAssertTrue(askCoach.waitForExistence(timeout: 5), "Expected the Ask your coach section identifier.")
    }

    /// Ask your Coach is session-only: closing and reopening it must show
    /// only the greeting again, never a prior turn's history.
    @MainActor
    func testAskCoachChatIsSessionOnly() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-weightUnitRaw", "kg"]
        app.launch()

        let coachButton = app.buttons["Coach's Corner"].firstMatch
        XCTAssertTrue(coachButton.waitForExistence(timeout: 5))
        tapWhenReady(coachButton)
        XCTAssertTrue(app.navigationBars["Coach's Corner"].waitForExistence(timeout: 5))

        let askCoach = app.descendants(matching: .any)["coach-corner-ask-coach"].firstMatch
        scrollUntilHittable(askCoach, in: app)
        tapWhenReady(askCoach)

        let greeting = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Ask me about your training'")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Expected the chat's opening greeting.")

        let suggestedPrompt = app.buttons["Why this readiness score?"].firstMatch
        XCTAssertTrue(suggestedPrompt.waitForExistence(timeout: 5), "Expected a suggested-prompt chip.")
        tapWhenReady(suggestedPrompt)

        let sentQuestion = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Why this readiness score'")).firstMatch
        XCTAssertTrue(sentQuestion.waitForExistence(timeout: 5), "Expected the sent question to appear in the transcript.")

        tapWhenReady(app.buttons["Done"].firstMatch)
        XCTAssertTrue(app.navigationBars["Coach's Corner"].waitForExistence(timeout: 5), "Expected to pop back to Coach's Corner, not close it.")

        tapWhenReady(askCoach)
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Expected the greeting again after reopening.")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Why this readiness score'")).firstMatch.exists,
            "Chat history must not persist across a reopen — the chat is session-only."
        )
    }

    /// "Review coach's version" only renders once the coach has a dose
    /// adjustment to show (readiness reduce-volume/deload, or a weekly
    /// review deload override) — there's no launch-argument seeding hook
    /// today to force either state deterministically. Covered functionally
    /// by `CoachAdjustmentsTests`/`CoachWeeklyReviewTests`; skip here rather
    /// than invent a new seeding framework.
    @MainActor
    func testReviewCoachsVersionOpensReviewScreen() throws {
        throw XCTSkip("No launch-argument seeding hook exists yet to force a coach dose adjustment or weekly deload override; covered at the unit level by CoachAdjustmentsTests/CoachWeeklyReviewTests.")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
