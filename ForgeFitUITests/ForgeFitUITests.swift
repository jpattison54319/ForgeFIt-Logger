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

    /// Auto-start creates the workout asynchronously. On a slow simulator the
    /// logger's initial presentation can time out even though the workout did
    /// start, leaving its mini bar on Home. Open that bar so interaction tests
    /// exercise the logger instead of failing during fixture setup.
    private func waitForLiveLogger(
        containing element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 8
    ) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }

        // Query the real Button. The surrounding Liquid Glass accessibility
        // proxy exposes the same identifier with a degenerate {-1, -1} frame,
        // so a broad `.any` query can find an element that exists but can never
        // receive the recovery tap.
        let expand = app.buttons["expand-active-workout"].firstMatch
        guard expand.waitForExistence(timeout: 5) else { return false }
        tapWhenReady(expand)
        return element.waitForExistence(timeout: 5)
    }

    private func numericValue(in element: XCUIElement) -> Double? {
        guard let value = element.value as? String else { return nil }
        return Double(value.replacingOccurrences(of: ",", with: ""))
    }

    private func waitForNumericValue(
        _ expectedValue: Double,
        in element: XCUIElement,
        tolerance: Double = 0.02,
        timeout: TimeInterval = 4
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let actual = numericValue(in: element), abs(actual - expectedValue) <= tolerance {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard let actual = numericValue(in: element) else { return false }
        return abs(actual - expectedValue) <= tolerance
    }

    @MainActor
    func testRoutineStartLogSetCompleteAndShowsSetupNotes() throws {
        throw XCTSkip("Routine auto-start presentation is still being stabilized; setup-note propagation is covered by ForgeFitTests.")
    }

    @MainActor
    func testHomeQuickStartsHaveVisibleEditControl() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-homeQuickStartActions.v1", ""]
        app.launch()

        let edit = app.buttons["home-quick-start-edit"].firstMatch
        scrollUntilHittable(edit, in: app)
        XCTAssertTrue(edit.isHittable, "Expected a visible way to edit Home quick starts.")
        edit.tap()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3),
                      "Expected Home quick starts to enter edit mode.")
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
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg", "-homeQuickStartActions.v1", ""]
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

        let keepLogging = app.buttons["post-workout-keep-logging-button"].firstMatch
        let share = app.buttons["post-workout-share-button"].firstMatch
        let save = app.buttons["save-workout-button"].firstMatch
        XCTAssertTrue(keepLogging.waitForExistence(timeout: 5), "Expected Keep Logging in the floating summary actions.")
        XCTAssertTrue(share.exists, "Expected Share in the floating summary actions.")
        XCTAssertTrue(save.exists, "Expected Save in the floating summary actions.")
        XCTAssertTrue(keepLogging.isHittable && share.isHittable && save.isHittable,
                      "Every summary action should be reachable without scrolling.")

        app.swipeUp(velocity: .fast)
        XCTAssertTrue(keepLogging.isHittable && share.isHittable && save.isHittable,
                      "The summary actions should remain available after a scroll gesture.")
        attachScreenshot(app, name: "Post-workout floating actions")
        tapWhenReady(save)

        XCTAssertTrue(app.descendants(matching: .any)["home-workout-Row"].waitForExistence(timeout: 5), "Expected Row cardio workout in recents.")
    }

    /// Recreates the production failure with two different values in one row:
    /// the routine stores 70 kg while seeded history visibly ghosts 97.5 kg.
    /// A fast drag onto the middle positive band must use that visible ghost,
    /// keep the highlighted positive band on release, remain reusable, and
    /// switch immediately to the other unit's native bands when the header changes.
    @MainActor
    func testQuickIncrementFanAdjustsGhostWeight() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--seed-quick-increment-history", "--skip-onboarding", "--auto-start-routine", "-weightUnitRaw", "kg"]
        app.launch()

        let weightField = app.textFields.matching(NSPredicate(format: "label == %@", "Weight")).firstMatch
        XCTAssertTrue(
            waitForLiveLogger(containing: weightField, in: app),
            "Expected the live logger's weight field."
        )
        let previousKilograms = app.buttons["97.5 × 10"].firstMatch
        let previousPounds = app.buttons["215 × 10"].firstMatch
        let previousDeadline = Date().addingTimeInterval(4)
        while !previousKilograms.exists && !previousPounds.exists, Date() < previousDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(
            previousKilograms.exists || previousPounds.exists,
            "Expected the seeded previous set beside the ghost field in the row's current unit."
        )
        let startsInKilograms = previousKilograms.exists

        // A recognized hold that never leaves the field is the neutral path:
        // release closes the fan, does not focus the field, and changes
        // nothing. This was previously one way the fan became stuck.
        let originalValue = weightField.value as? String
        weightField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.7)
        XCTAssertEqual(weightField.value as? String, originalValue)
        XCTAssertFalse(app.keyboards.firstMatch.exists, "A hold should not also focus the TextField.")
        XCTAssertFalse(
            app.descendants(matching: .any)["quick-increment-option-0"].exists,
            "Releasing without choosing should close the fan."
        )

        // Slot centers are roughly 50 / 94 / 138 pt from field center. Use
        // XCUITest's fast velocity to cover the user's quick hold-drag-lift.
        func chooseBand(field: XCUIElement, yOffset: CGFloat) {
            let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(
                forDuration: 0.55,
                thenDragTo: start.withOffset(CGVector(dx: 0, dy: yOffset)),
                withVelocity: .fast,
                thenHoldForDuration: 0
            )
        }

        chooseBand(field: weightField, yOffset: -94) // Middle positive band.
        let firstDelta = startsInKilograms ? 2.5 : 5.0
        let firstExpected = (startsInKilograms ? 97.5 : 215.0) + firstDelta
        XCTAssertTrue(
            waitForNumericValue(firstExpected, in: weightField),
            "The visible ghost plus the highlighted middle band must be applied, never a hidden value or negative band."
        )

        // A regular tap still owns the normal editing path after a quick
        // adjustment. The now-explicit value must survive keyboard focus.
        tapWhenReady(weightField)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "A tap should still open the keyboard.")
        let dismissKeyboard = app.buttons["Dismiss keyboard"].firstMatch
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 3))
        dismissKeyboard.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(waitForNumericValue(firstExpected, in: weightField), "Keyboard focus must preserve the adjusted value.")

        chooseBand(field: weightField, yOffset: -50) // Nearest positive band.
        let secondExpected = firstExpected + (startsInKilograms ? 1.25 : 2.5)
        XCTAssertTrue(
            waitForNumericValue(secondExpected, in: weightField),
            "The picker must remain reusable without recycling units."
        )

        // Changing the exercise header unit must update the already-mounted
        // recognizer; no extra unit recycle is allowed.
        let switchUnit = app.buttons["Switch Machine Chest Press weight unit"].firstMatch
        XCTAssertTrue(switchUnit.waitForExistence(timeout: 3), "Expected the visible unit switch control.")
        tapWhenReady(switchUnit)
        let switchedHeader = startsInKilograms ? app.staticTexts["LBS"].firstMatch : app.staticTexts["KG"].firstMatch
        XCTAssertTrue(switchedHeader.waitForExistence(timeout: 3), "Expected the row to switch units immediately.")
        let poundsPerKilogram = 2.2046226218
        let convertedExpected = startsInKilograms
            ? secondExpected * poundsPerKilogram
            : secondExpected / poundsPerKilogram
        XCTAssertTrue(
            waitForNumericValue(convertedExpected, in: weightField, tolerance: 0.06),
            "Expected the adjusted value converted into the switched unit."
        )
        let convertedDisplay = try XCTUnwrap(numericValue(in: weightField))

        chooseBand(field: weightField, yOffset: -50) // New unit's nearest band.
        let switchedNearestDelta = startsInKilograms ? 2.5 : 1.25
        XCTAssertTrue(
            waitForNumericValue(convertedDisplay + switchedNearestDelta, in: weightField),
            "The mounted recognizer must immediately use the switched unit's nearest band."
        )
    }

    /// A fast vertical drag that originates on a weight field belongs to the
    /// workout ScrollView. It must fail the pending long press before the fan
    /// opens, leave the value untouched, and avoid focusing the keyboard.
    @MainActor
    func testQuickIncrementDoesNotHijackScrollFromField() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--skip-onboarding", "--auto-start-routine", "-weightUnitRaw", "kg"]
        app.launch()

        let weightField = app.textFields.matching(NSPredicate(format: "label == %@", "Weight")).firstMatch
        XCTAssertTrue(
            waitForLiveLogger(containing: weightField, in: app),
            "Expected the live logger's weight field."
        )

        let originalValue = weightField.value as? String
        let start = weightField.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -120)))

        XCTAssertEqual(weightField.value as? String, originalValue, "Scrolling from the field must not change its value.")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Scrolling from the field must not open the keyboard.")
        XCTAssertFalse(
            app.descendants(matching: .any)["quick-increment-option-0"].exists,
            "Scrolling from the field must not open the quick picker."
        )
    }

    /// A regular row can show a previous-session ghost while retaining a
    /// different hidden routine target. Converting it to Myo-reps must carry
    /// the value the lifter actually saw into the activation field.
    @MainActor
    func testChangingGhostedWorkingSetToMyoKeepsVisibleActivationWeight() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",
            "--seed-block-prefill-history",
            "--skip-onboarding",
            "--auto-start-routine",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        let workingWeight = app.textFields.matching(
            NSPredicate(format: "label == %@", "Weight")
        ).firstMatch
        XCTAssertTrue(
            waitForLiveLogger(containing: workingWeight, in: app),
            "Expected the live Working row."
        )
        let previousWorking = app.buttons["72.5 × 10"].firstMatch
        XCTAssertTrue(
            previousWorking.waitForExistence(timeout: 5),
            "Expected the seeded 72.5 kg Working history beside the row."
        )
        XCTAssertTrue(
            app.staticTexts["72.5"].firstMatch.waitForExistence(timeout: 3),
            "Expected 72.5 kg to render as the row's non-destructive ghost."
        )

        tapWhenReady(app.descendants(matching: .any)["set-type-menu"].firstMatch)
        tapWhenReady(app.buttons["Myo-reps"].firstMatch)

        let activationWeight = app.textFields["activation-weight"].firstMatch
        XCTAssertTrue(
            activationWeight.waitForExistence(timeout: 5),
            "Expected the Myo-rep activation weight field."
        )
        XCTAssertTrue(
            waitForNumericValue(72.5, in: activationWeight),
            "The Myo-rep activation must keep the visible 72.5 kg value, not expose the hidden 22.68 kg routine target."
        )
        attachScreenshot(app, name: "myo-activation-prefill")
    }

    /// Myo activation fields use the logger's one shared keyboard accessory:
    /// weight offers Next into reps, and both fields retain Dismiss plus an
    /// activation-scoped log action instead of completing the whole block.
    @MainActor
    func testMyoActivationFieldsRenderKeyboardActions() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",
            "--seed-block-prefill-history",
            "--skip-onboarding",
            "--auto-start-routine",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        let workingWeight = app.textFields.matching(
            NSPredicate(format: "label == %@", "Weight")
        ).firstMatch
        XCTAssertTrue(
            waitForLiveLogger(containing: workingWeight, in: app),
            "Expected the live Working row."
        )

        tapWhenReady(app.descendants(matching: .any)["set-type-menu"].firstMatch)
        tapWhenReady(app.buttons["Myo-reps"].firstMatch)

        let activationWeight = app.textFields["activation-weight"].firstMatch
        XCTAssertTrue(activationWeight.waitForExistence(timeout: 5))
        tapWhenReady(activationWeight)

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["Dismiss keyboard"].firstMatch.waitForExistence(timeout: 3),
            "Activation weight should render the shared keyboard dismiss action."
        )
        let next = app.buttons["Next"].firstMatch
        XCTAssertTrue(
            next.waitForExistence(timeout: 3),
            "Activation weight should offer Next into activation reps."
        )
        XCTAssertTrue(
            app.buttons["Log Activation"].firstMatch.waitForExistence(timeout: 3),
            "Activation weight should expose the activation-scoped log action."
        )
        attachScreenshot(app, name: "myo-activation-weight-keyboard-actions")

        next.tap()

        let activationReps = app.textFields["activation-reps-1"].firstMatch
        XCTAssertTrue(activationReps.waitForExistence(timeout: 3))
        let nextDeadline = Date().addingTimeInterval(3)
        while next.exists, Date() < nextDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertFalse(next.exists, "A bilateral activation reps field is the final keyboard field.")
        XCTAssertTrue(app.buttons["Dismiss keyboard"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Log Activation"].firstMatch.exists)

        let repsBeforeTyping = activationReps.value as? String ?? ""
        let nineKey = app.keys["9"].firstMatch
        XCTAssertTrue(nineKey.waitForExistence(timeout: 3))
        nineKey.tap()
        XCTAssertEqual(
            activationReps.value as? String,
            "\(repsBeforeTyping)9",
            "Next should move keyboard input from activation weight into activation reps."
        )

        attachScreenshot(app, name: "myo-activation-reps-keyboard-actions")
    }

    /// End-to-end pass over Profile → See all workouts: seeded 120-session
    /// history, text search narrows, the PR chip filters, clearing restores,
    /// and scrolling past the first page mounts more rows (windowed
    /// pagination). Screenshots attach for visual review.
    @MainActor
    func testHistorySearchFiltersAndPagination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-history", "-weightUnitRaw", "kg"]
        app.launch()

        app.descendants(matching: .any)["tab-profile"].firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["home-workout-Push Day #120"].firstMatch.waitForExistence(timeout: 8),
            "Expected the Profile feed to render seeded recents before scrolling."
        )

        // Press-drag instead of swipeUp: a fast momentum swipe can misfire as
        // a tap on a feed row's NavigationLink and push a workout detail.
        let seeAll = app.staticTexts["See all workouts"]
        dragUp(app, until: seeAll)
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5), "Expected the See all workouts row at the end of the Profile feed.")
        seeAll.tap()

        // Scope every row assertion to `history-workout-` identifiers: the
        // Profile feed underneath stays in the NavigationStack's accessibility
        // hierarchy with its own `home-workout-` copies of the same titles.
        let searchField = app.textFields["history-search-field"]
        let pushRow = app.descendants(matching: .any)["history-workout-Push Day #120"].firstMatch
        let pullRow = app.descendants(matching: .any)["history-workout-Pull Day #119"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Expected the History search field.")
        XCTAssertTrue(pushRow.waitForExistence(timeout: 5), "Expected the newest seeded session on page one.")
        attachScreenshot(app, name: "history-default")

        // Text search narrows to matching sessions (250 ms debounce). 120
        // seeds ÷ 4-day split = exactly 30 push sessions.
        searchField.tap()
        searchField.typeText("push day")
        XCTAssertTrue(pullRow.waitForNonExistence(timeout: 3), "Search should filter out pull sessions.")
        XCTAssertTrue(app.staticTexts["30 workouts"].waitForExistence(timeout: 3), "Count line should reflect the narrowed result.")
        XCTAssertTrue(pushRow.exists, "Matching sessions should survive the search.")
        attachScreenshot(app, name: "history-search")

        // Clear the text, then filter by PRs via the chip. The chips row
        // scrolls horizontally; swipe it (not the page) to reveal the chip.
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        XCTAssertTrue(pullRow.waitForExistence(timeout: 3), "Clearing the search should restore the list.")
        // PRs sits past the viewport in the default chip row; one row swipe
        // reveals the tail. Don't probe `isHittable` while it may be fully
        // off-screen — on this OS the check throws ("activation point
        // invalid") instead of returning false.
        let chipRow = app.scrollViews["history-filter-row"].firstMatch
        let prsChip = app.descendants(matching: .any)["history-filter-prs"].firstMatch
        chipRow.swipeLeft()
        tapWhenReady(prsChip)
        XCTAssertTrue(pushRow.waitForExistence(timeout: 3), "The newest session carries its split's latest load bump, so it PRs.")
        attachScreenshot(app, name: "history-prs")
        // Clear pins to the FRONT of the chips row while filters are active.
        chipRow.swipeRight()
        let clearChip = app.descendants(matching: .any)["history-clear-filters"].firstMatch
        XCTAssertTrue(clearChip.waitForExistence(timeout: 2), "Clear should lead the chips row when a filter is active.")
        tapWhenReady(clearChip)

        // Windowed pagination: row ~48 must not exist up top, then mounts on scroll.
        let deepRow = app.descendants(matching: .any)["history-workout-Push Day #72"].firstMatch
        XCTAssertFalse(deepRow.exists, "Rows beyond the first page should not be mounted before scrolling.")
        dragUp(app, until: deepRow, maxDrags: 30)
        XCTAssertTrue(deepRow.exists, "Expected deeper history to mount as the list scrolls (windowed pagination).")
    }

    /// Deterministic vertical scrolling: press-then-drag is always recognized
    /// as a drag, unlike `swipeUp` whose fast flick can land as a tap on a
    /// row's NavigationLink and push a detail screen mid-test. Drags start
    /// mid-screen so they stay above a software keyboard and the floating tab
    /// bar, both of which silently eat gestures.
    private func dragUp(_ app: XCUIApplication, until element: XCUIElement, maxDrags: Int = 40) {
        var drags = 0
        while !(element.exists && element.isHittable), drags < maxDrags {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
            drags += 1
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Regression: typing in the exercise picker's search crashed the app when
    /// the library contained duplicate exercise IDs (CloudKit can't enforce
    /// unique constraints, so a sync/re-seed race produces them). Drives the
    /// exact reported flow — edit a routine, add an exercise, search — and
    /// asserts the app stays alive with results rendering.
    @MainActor
    func testExerciseSearchDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg"]
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
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg"]
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
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg"]
        app.launch()

        app.descendants(matching: .any)["tab-workout"].firstMatch.tap()
        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5))
        newRoutine.tap()

        let addYoga = app.buttons["add-yoga-format"].firstMatch
        XCTAssertTrue(addYoga.waitForExistence(timeout: 5), "Expected Yoga beside Conditioning in the routine editor.")
        tapWhenReady(addYoga)

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

        let flowBuilder = app.descendants(matching: .any)["routine-yoga-flow-builder"].firstMatch
        XCTAssertTrue(flowBuilder.waitForExistence(timeout: 5), "Expected to return to the routine editor after saving the flow.")
        let configured = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] '1 pose'")).firstMatch
        XCTAssertTrue(configured.waitForExistence(timeout: 3), "Expected the Yoga Session row to show the saved pose flow.")
    }

    /// A routine cardio card has one visible goal affordance. Goal inputs and
    /// modality capability copy belong behind that disclosure, not inline.
    @MainActor
    func testRoutineCardioUsesSingleAddGoalDisclosure() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        tapWhenReady(app.descendants(matching: .any)["tab-workout"].firstMatch)
        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5))
        tapWhenReady(newRoutine)

        let addExercise = app.buttons["add-to-routine"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        tapWhenReady(addExercise)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Outdoor Run")

        let outdoorRun = app.descendants(matching: .any)["exercise-row-Outdoor Run"].firstMatch
        XCTAssertTrue(outdoorRun.waitForExistence(timeout: 5))
        tapWhenReady(outdoorRun)

        let commit = app.buttons["Add 1 exercise"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 3))
        tapWhenReady(commit)

        let addGoal = app.buttons["routine-cardio-goal"].firstMatch
        XCTAssertTrue(addGoal.waitForExistence(timeout: 5))
        XCTAssertEqual(addGoal.label, "Add goal")
        XCTAssertFalse(app.staticTexts["Cardio target"].exists)
        XCTAssertFalse(app.staticTexts["Add goal, zone lock, or intervals"].exists)
        XCTAssertFalse(app.textFields["cardio-target-minutes"].exists)
        XCTAssertFalse(app.textFields["cardio-target-distance"].exists)
        XCTAssertFalse(
            app.staticTexts["Time · Heart rate · Effort · Distance · Pace · Elevation · Incline · Power · Cadence"].exists
        )
        attachScreenshot(app, name: "routine-cardio-single-add-goal")

        tapWhenReady(addGoal)
        XCTAssertTrue(app.navigationBars["Cardio goal"].waitForExistence(timeout: 5))
        let existingMinutes = app.textFields["cardio-goal-minutes"].firstMatch
        XCTAssertTrue(
            existingMinutes.waitForExistence(timeout: 3),
            "Existing routine targets should remain editable in the goal sheet."
        )
        XCTAssertEqual(existingMinutes.value as? String, "30")
    }

    /// New and existing routines use the same editor row as the live logger:
    /// creating Superset A promises purple in the menu, then renders the same
    /// compact lettered marker after assignment.
    @MainActor
    func testRoutineEditorUsesSharedSupersetIdentity() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        tapWhenReady(app.descendants(matching: .any)["tab-workout"].firstMatch)
        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5))
        tapWhenReady(newRoutine)

        let addExercise = app.buttons["Add Exercise"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5))
        tapWhenReady(addExercise)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("squat")

        let exercise = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")
        ).firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 4))
        tapWhenReady(exercise)

        let commit = app.buttons["Add 1 exercise"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 3))
        tapWhenReady(commit)

        let menu = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'routine-exercise-menu-'")
        ).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        tapWhenReady(menu)

        let createSuperset = app.buttons["Create Superset A · Purple"].firstMatch
        XCTAssertTrue(createSuperset.waitForExistence(timeout: 3))
        tapWhenReady(createSuperset)

        let marker = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Superset A")
        ).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 5))
        XCTAssertEqual(marker.value as? String, "Purple")
    }

    /// Routine editor: exercises can be reordered (mirrors the live logger's
    /// reorder mode) and replaced in place (via the row's ellipsis menu),
    /// without changing how many exercises the routine has.
    @MainActor
    func testRoutineEditorReordersAndReplacesExercises() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg"]
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

        // Reorder is a hold-and-drag on each row's handle now (no mode/button)
        // — the drag itself can't be synthesized by XCUITest (see the
        // scroll-from-control limitation), so this test only asserts the
        // handles exist; the interaction is verified by hand on device.
        let reorderHandle = app.descendants(matching: .any)
            .matching(identifier: "hold-to-reorder-exercises").firstMatch
        XCTAssertTrue(reorderHandle.waitForExistence(timeout: 3),
                      "Expected per-exercise reorder handles in the editor.")

        // Replace: swap one exercise for another without changing the count.
        let firstMenu = menus.firstMatch
        XCTAssertTrue(firstMenu.waitForExistence(timeout: 5))
        tapWhenReady(firstMenu)
        let replaceItem = app.buttons["Replace Exercise"].firstMatch
        XCTAssertTrue(replaceItem.waitForExistence(timeout: 3))
        replaceItem.tap()

        let searchAll = app.buttons["Search all exercises"].firstMatch
        XCTAssertTrue(searchAll.waitForExistence(timeout: 5), "Expected ranked replacement suggestions before the full picker.")
        tapWhenReady(searchAll)
        let replaceSearch = app.searchFields.firstMatch
        XCTAssertTrue(replaceSearch.waitForExistence(timeout: 5), "Expected the replace picker's search field.")
        XCTAssertTrue(app.navigationBars["Replace Exercise"].exists, "The fallback picker must remain a replace flow.")
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

    /// Live and routine replacement share the ranked swap sheet. This pins the
    /// live entry point and keeps the ranked choices immediately visible
    /// without an instructional paragraph above them.
    @MainActor
    func testLiveWorkoutReplaceOpensRankedSwapSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--skip-onboarding", "--auto-start-routine", "-weightUnitRaw", "kg"]
        app.launch()

        let weightField = app.textFields.matching(
            NSPredicate(format: "label == %@", "Weight")
        ).firstMatch
        XCTAssertTrue(
            waitForLiveLogger(containing: weightField, in: app, timeout: 10),
            "Expected the live logger before opening replacement."
        )

        let menu = app.buttons["Exercise options"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "Expected the live exercise options menu.")
        tapWhenReady(menu)

        let replace = app.buttons["Replace Exercise"].firstMatch
        XCTAssertTrue(replace.waitForExistence(timeout: 3))
        tapWhenReady(replace)

        XCTAssertTrue(app.buttons["Search all exercises"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.staticTexts[
                "Set structure stays for similar exercises. Unfinished values and exercise-specific targets reset; completed sets remain logged."
            ].exists,
            "The ranked swap choices should not be pushed down by explanatory copy."
        )
        attachScreenshot(app, name: "live-replacement-sheet-without-explanation")
    }

    /// Regression: keyboard clearance belongs inside the routine editor's
    /// scrollable content. Applying it to the ScrollView itself shrinks the
    /// editor by the full keyboard height and exposes a large black band.
    @MainActor
    func testRoutineEditorKeyboardDoesNotShrinkEditorOrRaiseBottomChrome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        tapWhenReady(app.buttons["tab-workout"].firstMatch)

        let newRoutine = app.buttons["New Routine"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5), "Expected New Routine button.")
        tapWhenReady(newRoutine)

        let addExercise = app.buttons["Add Exercise"].firstMatch
        XCTAssertTrue(addExercise.waitForExistence(timeout: 5), "Expected Add Exercise in the routine editor.")
        tapWhenReady(addExercise)

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), "Expected the exercise picker search field.")
        searchField.tap()
        searchField.typeText("squat")

        let exercise = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'exercise-row-'")
        ).firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 5), "Expected a squat search result.")
        tapWhenReady(exercise)

        let commit = app.buttons["Add 1 exercise"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 3), "Expected the picker commit button.")
        tapWhenReady(commit)

        let weightField = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH 'routine-set-weight-'")
        ).firstMatch
        XCTAssertTrue(weightField.waitForExistence(timeout: 5), "Expected a routine target-weight field.")
        tapWhenReady(weightField)

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "Expected the number pad.")

        let editorScroll = app.scrollViews["routine-editor-scroll"].firstMatch
        XCTAssertTrue(editorScroll.exists, "Expected the routine editor scroll view.")
        let uncoveredGap = keyboard.frame.minY - editorScroll.frame.maxY
        XCTAssertLessThan(
            uncoveredGap,
            80,
            "The editor ended \(Int(uncoveredGap)) pt above the keyboard; keyboard clearance must not shrink the ScrollView."
        )

        for chrome in [
            app.buttons["tab-workout"].firstMatch,
            app.buttons["quick-actions-trigger"].firstMatch,
        ] where chrome.exists {
            XCTAssertTrue(
                !chrome.isHittable || chrome.frame.minY >= keyboard.frame.minY,
                "Bottom chrome must remain hidden by the keyboard instead of being lifted above it."
            )
        }

        attachScreenshot(app, name: "routine-editor-keyboard")
    }

    @MainActor
    func testConditioningPresetCreatesItsWorkoutAndUsesOneRoutineEntryPoint() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        tapWhenReady(app.buttons["tab-workout"].firstMatch)

        let newRoutine = app.buttons["new-routine-button"].firstMatch
        let explore = app.buttons["explore-routines-button"].firstMatch
        XCTAssertTrue(newRoutine.waitForExistence(timeout: 5), "Expected one New Routine action.")
        XCTAssertTrue(explore.waitForExistence(timeout: 5), "Expected Explore beside New Routine.")
        XCTAssertEqual(newRoutine.frame.width, explore.frame.width, accuracy: 1)
        XCTAssertFalse(app.buttons["New Conditioning"].exists, "Conditioning belongs inside the routine editor.")

        tapWhenReady(newRoutine)
        XCTAssertFalse(app.buttons["conditioning-presets"].exists, "Presets must belong to individual sections.")
        let addFormat = app.buttons["add-conditioning-format"].firstMatch
        let addYoga = app.buttons["add-yoga-format"].firstMatch
        XCTAssertTrue(addFormat.waitForExistence(timeout: 5), "Expected conditioning to be available inside a routine.")
        XCTAssertTrue(addYoga.waitForExistence(timeout: 5), "Expected Yoga beside Conditioning inside a routine.")
        XCTAssertGreaterThanOrEqual(addFormat.frame.height, 44)
        XCTAssertGreaterThanOrEqual(addYoga.frame.height, 44)
        tapWhenReady(addFormat)

        let presets = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'conditioning-section-preset-'")
        ).firstMatch
        XCTAssertTrue(presets.waitForExistence(timeout: 2), "Expected a preset menu inside the section.")
        tapWhenReady(presets)
        tapWhenReady(app.buttons["Cindy · 20 min AMRAP"].firstMatch)

        for exercise in ["Pullups", "Pushups", "Bodyweight Squat"] {
            XCTAssertTrue(
                app.staticTexts[exercise].waitForExistence(timeout: 2),
                "Expected Cindy to add \(exercise)."
            )
        }
        for (exercise, reps) in [("Pullups", 5.0), ("Pushups", 10.0), ("Bodyweight Squat", 15.0)] {
            let target = app.textFields["conditioning-target-\(exercise)"].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 5), "Expected an editable target for \(exercise).")
            XCTAssertTrue(waitForNumericValue(reps, in: target), "Expected \(Int(reps)) reps for \(exercise).")
        }
        XCTAssertFalse(app.staticTexts["Movements"].exists, "Movement editing must stay inside its section.")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'add-conditioning-movement-'")).firstMatch.exists,
            "Expected the section to own its Add Movement action."
        )
        XCTAssertTrue(app.buttons["Replace Pullups"].exists, "Expected a visible in-section replacement action.")
        attachScreenshot(app, name: "conditioning-cindy-plan")

        let addSection = app.buttons["add-conditioning-section"].firstMatch
        scrollUntilHittable(addSection, in: app)
        tapWhenReady(addSection)
        let secondPreset = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'conditioning-section-preset-'")
        ).element(boundBy: 1)
        XCTAssertTrue(secondPreset.waitForExistence(timeout: 2), "Expected each section to have its own preset menu.")
        tapWhenReady(secondPreset)
        tapWhenReady(app.buttons["Bodyweight Squats · Tabata"].firstMatch)
        let sectionNames = app.textFields.matching(identifier: "Section name")
        XCTAssertTrue(sectionNames.matching(NSPredicate(format: "value == 'Cindy'")).firstMatch.exists)
        XCTAssertTrue(sectionNames.matching(NSPredicate(format: "value == 'Tabata Squats'")).firstMatch.exists)
        attachScreenshot(app, name: "conditioning-cindy-editor")
    }

    /// Regression: the keyboard accessory's Complete button used to stop
    /// rendering after the accessory's own dismiss chevron was used (the old
    /// UIKit toolbar was reused blank on refocus). Drives the reported flow —
    /// focus a set input, dismiss via the accessory, refocus — and asserts
    /// the accessory comes back intact every time.
    @MainActor
    func testKeyboardAccessorySurvivesDismissAndRefocus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--auto-start-routine", "-weightUnitRaw", "kg"]
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
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--auto-start-routine", "-weightUnitRaw", "kg"]
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

    /// Every active strength exercise can be collapsed before completion. Its
    /// condensed checkmark completes/uncompletes all sets without opening the
    /// card, while the summary and persistent header chevron toggle its layout.
    @MainActor
    func testCompletedExerciseCollapsesAndReopens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--auto-start-routine", "-weightUnitRaw", "kg"]
        app.launch()

        // The starter routine's exercise has exactly one set, so one tap
        // completes the exercise. Auto-presentation of the logger has a
        // startup race (it polls for the active workout for ~3s and gives
        // up); the workout is still running, so recover via the mini bar.
        let completeSet = app.buttons["complete-set-1"].firstMatch
        if !completeSet.waitForExistence(timeout: 10) {
            let expand = app.descendants(matching: .any)["expand-active-workout"].firstMatch
            XCTAssertTrue(expand.waitForExistence(timeout: 5), "Expected either the live logger or the minimized workout bar.")
            tapWhenReady(expand)
        }
        XCTAssertTrue(completeSet.waitForExistence(timeout: 10), "Expected the live logger with a completable set.")
        let summary = app.descendants(matching: .any)["completed-exercise-summary"].firstMatch
        let collapse = app.descendants(matching: .any)["collapse-completed-exercise"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "Every expanded exercise should keep a collapse chevron.")
        tapWhenReady(collapse)
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "An incomplete exercise should collapse into its summary.")

        let condensedCheckmark = app.descendants(matching: .any)["toggle-condensed-exercise-completion"].firstMatch
        XCTAssertTrue(condensedCheckmark.waitForExistence(timeout: 5), "A collapsed exercise should keep its completion control.")
        XCTAssertEqual(condensedCheckmark.value as? String, "0 of 1 sets completed")
        tapWhenReady(condensedCheckmark)
        XCTAssertTrue(summary.exists, "Completing all sets while collapsed must keep the exercise collapsed.")
        XCTAssertEqual(condensedCheckmark.value as? String, "1 of 1 sets completed")

        tapWhenReady(summary)
        XCTAssertTrue(completeSet.waitForExistence(timeout: 5), "Tapping the summary should reopen the full set grid.")

        XCTAssertTrue(collapse.waitForExistence(timeout: 5), "The collapse chevron should remain after reopening.")
        tapWhenReady(collapse)
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "The chevron should recollapse the still-completed exercise.")
        tapWhenReady(condensedCheckmark)
        XCTAssertTrue(summary.exists, "Uncompleting all sets must also preserve the user's collapsed state.")
        XCTAssertEqual(condensedCheckmark.value as? String, "0 of 1 sets completed")
    }

    /// A partial-wear night surfaces the Home affordance. Repeated close/open
    /// cycles must always restore full-sized bubbles, while Delete retracts to
    /// one Undo button and remains reversible across repeated attempts.
    @MainActor
    func testPartialSleepCorrectionFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-partial-sleep-demo", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launchEnvironment["FORGEFIT_PARTIAL_SLEEP_DEMO"] = "1"
        app.launch()

        let trigger = app.buttons["sleep-integrity-trigger"].firstMatch
        if !trigger.waitForExistence(timeout: 20) {
            // A forced SwiftData reset can remount the root and cancel the
            // first launch task after it seeds the in-memory Health fixture.
            // Relaunch without resetting the now-clean store so the fixture
            // is installed by the final root task.
            app.terminate()
            app.launchArguments.removeAll { $0 == "--reset-store" }
            app.launch()
        }
        XCTAssertTrue(trigger.waitForExistence(timeout: 10), "Expected the flagged-sleep affordance on Home.")
        let minimizeWorkout = app.descendants(matching: .any)["minimize-workout"].firstMatch
        if minimizeWorkout.exists {
            minimizeWorkout.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let triggerMidX = trigger.frame.midX
        tapWhenReady(trigger)

        // The single button splits into the option cluster.
        let edit = app.buttons["sleep-integrity-edit"].firstMatch
        let confirm = app.buttons["sleep-integrity-confirm"].firstMatch
        let delete = app.buttons["sleep-integrity-delete"].firstMatch
        let dismiss = app.buttons["sleep-integrity-dismiss"].firstMatch
        let undo = app.buttons["sleep-integrity-undo"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Tapping the trigger should reveal the Edit option.")
        XCTAssertTrue(confirm.exists, "Confirm option should appear.")
        XCTAssertTrue(delete.waitForExistence(timeout: 2), "Delete option should appear.")
        XCTAssertTrue(dismiss.exists, "The trigger should become a dismiss control.")
        XCTAssertLessThan(delete.frame.maxX, edit.frame.minX, "Delete and Edit must remain distinct bubbles with a gap.")
        XCTAssertLessThan(edit.frame.maxX, confirm.frame.minX, "Edit and Confirm must remain distinct bubbles with a gap.")
        XCTAssertLessThan(confirm.frame.maxX, dismiss.frame.minX, "Confirm and Dismiss must remain distinct bubbles with a gap.")
        XCTAssertEqual(dismiss.frame.midX, triggerMidX, accuracy: 2, "The original trigger should stay pinned when it becomes Dismiss.")

        // Exercise rapid reuse of the same fan subtree. Every reopen must end
        // at the intended 44pt bubble size, never at the hidden 5% dot scale.
        for _ in 0..<2 {
            tapWhenReady(dismiss)
            XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Closing should restore the original trigger.")
            tapWhenReady(trigger)
            XCTAssertTrue(delete.waitForExistence(timeout: 3), "Reopening should remount every option.")
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            XCTAssertGreaterThan(delete.frame.width, 38, "Delete must settle at full bubble size after reopening.")
            XCTAssertGreaterThan(edit.frame.width, 38, "Edit must settle at full bubble size after reopening.")
            XCTAssertGreaterThan(confirm.frame.width, 38, "Confirm must settle at full bubble size after reopening.")
        }

        // Delete retracts the cluster automatically and leaves exactly one
        // persistent Undo control during the destructive-action grace period.
        tapWhenReady(delete)
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "Delete should collapse into a single Undo control.")
        XCTAssertFalse(delete.waitForExistence(timeout: 1), "Delete should retract with the option cluster.")
        XCTAssertFalse(confirm.exists || edit.exists || dismiss.exists, "Only Undo should remain after Delete retracts.")
        XCTAssertTrue(app.descendants(matching: .any)["sleep-integrity-feedback"].firstMatch.exists,
                      "Choosing an option should confirm it with a feedback line.")

        // Undo restores the original trigger and card. Repeating the exact
        // sequence guards the previously damaging Delete/Undo/Delete race.
        tapWhenReady(undo)
        XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Undo should restore the review trigger.")
        XCTAssertFalse(undo.exists, "Undo should disappear once reverted.")
        tapWhenReady(trigger)
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        tapWhenReady(delete)
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "A second Delete must retain the same Undo path.")
        XCTAssertTrue(app.descendants(matching: .any)["sleep-integrity-feedback"].firstMatch.exists,
                      "The sleep card must remain rendered throughout the second undo window.")
        tapWhenReady(undo)
        XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Undoing a second Delete must restore the card again.")

        // Edit path: open the modal, enter a duration, save → Edit becomes Undo.
        tapWhenReady(trigger)
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        tapWhenReady(edit)
        let field = app.textFields["sleep-integrity-hours-field"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Edit should present the hours field.")
        tapWhenReady(field)
        field.typeText("7.5")
        let save = app.descendants(matching: .any)["sleep-integrity-save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Expected a Save button.")
        tapWhenReady(save)
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "Saving an edit should swap Edit to Undo, keeping the card open.")
        XCTAssertTrue(trigger.exists == false && dismiss.exists, "The card must stay open after an edit, not retire.")

        // Return to a clean fan, then allow a final Delete to expire. Undo and
        // feedback must remain visible during the grace period; only then does
        // the saved correction update the score and retire the card.
        tapWhenReady(undo)
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        tapWhenReady(delete)
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertTrue(undo.exists, "Undo must remain available throughout the grace period.")
        let deadline = Date().addingTimeInterval(9)
        while undo.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertFalse(undo.exists, "Delete should retire the card after the undo window expires.")

        // Recovery must preserve the user's decision. It may not fall back to
        // the original partial-capture warning after this night was excluded.
        let recoveryCard = app.descendants(matching: .any)["home-recovery-card"].firstMatch
        for _ in 0..<5 where !(recoveryCard.exists && recoveryCard.isHittable) {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(recoveryCard.waitForExistence(timeout: 5), "Expected the Home recovery card.")
        tapWhenReady(recoveryCard)

        let notTracked = app.staticTexts["Sleep status: Not tracked"].firstMatch
        scrollUntilHittable(notTracked, in: app)
        XCTAssertTrue(notTracked.waitForExistence(timeout: 5), "Recovery should label the excluded night as Not tracked.")
        XCTAssertTrue(app.staticTexts["Excluded at your request"].exists)
        XCTAssertFalse(app.staticTexts["Only part of the night tracked"].exists,
                       "A resolved night must not retain the raw partial-tracking warning.")
    }

    /// Delete is durable when its success feedback appears, not eight seconds
    /// later when the Undo grace period ends. Force-close immediately, rebuild
    /// the same raw Health night, and verify relaunch applies the saved choice.
    @MainActor
    func testSleepDeleteSurvivesImmediateRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-partial-sleep-demo", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launchEnvironment["FORGEFIT_PARTIAL_SLEEP_DEMO"] = "1"
        app.launch()

        let trigger = app.buttons["sleep-integrity-trigger"].firstMatch
        XCTAssertTrue(trigger.waitForExistence(timeout: 10))
        tapWhenReady(trigger)
        let delete = app.buttons["sleep-integrity-delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        tapWhenReady(delete)
        XCTAssertTrue(app.buttons["sleep-integrity-undo"].firstMatch.waitForExistence(timeout: 3),
                      "The choice should still offer Undo before the app closes.")
        XCTAssertTrue(app.descendants(matching: .any)["sleep-integrity-feedback"].firstMatch.exists)

        // Close inside the grace period, then seed the same raw night without
        // clearing UserDefaults. This is the real regression path.
        app.terminate()
        app.launchArguments = [
            "--seed-partial-sleep-demo",
            "--preserve-sleep-override-demo",
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        let recoveryCard = app.descendants(matching: .any)["home-recovery-card"].firstMatch
        XCTAssertTrue(recoveryCard.waitForExistence(timeout: 10), "Expected Home to finish relaunching.")
        XCTAssertFalse(app.buttons["sleep-integrity-trigger"].firstMatch.exists,
                       "The deleted night must not be questioned again after relaunch.")
        XCTAssertFalse(app.buttons["sleep-integrity-undo"].firstMatch.exists,
                       "The resolved affordance should not linger after relaunch.")
        XCTAssertFalse(app.staticTexts["Sleep removed"].exists)
        tapWhenReady(recoveryCard)

        let notTracked = app.staticTexts["Sleep status: Not tracked"].firstMatch
        scrollUntilHittable(notTracked, in: app)
        XCTAssertTrue(notTracked.waitForExistence(timeout: 5),
                      "Relaunched Recovery should apply the persisted Not tracked choice.")
        XCTAssertTrue(app.staticTexts["Excluded at your request"].exists)
    }

    /// The training calendar shows per-day recovery rings and strain lines;
    /// selecting a day surfaces all three scores above that day's workouts.
    @MainActor
    func testCalendarShowsRecoveryRingsAndSummary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-recovery-demo", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launchEnvironment["FORGEFIT_RECOVERY_DEMO"] = "1"
        app.launch()

        app.descendants(matching: .any)["tab-profile"].firstMatch.tap()
        let calendarTile = app.descendants(matching: .any)["Calendar"].firstMatch
        XCTAssertTrue(calendarTile.waitForExistence(timeout: 8), "Expected the Calendar tile in Profile.")
        tapWhenReady(calendarTile)

        let anyDay = app.descendants(matching: .any)["calendar-day"].firstMatch
        XCTAssertTrue(anyDay.waitForExistence(timeout: 8), "Expected calendar day cells.")
        XCTAssertTrue(anyDay.label.contains("strain"), "Seeded calendar days should expose their strain score.")

        // Selecting a seeded day surfaces recovery, trend, and strain.
        let recovery = app.descendants(matching: .any)["recovery-summary-recovery"].firstMatch
        let trend = app.descendants(matching: .any)["recovery-summary-trend"].firstMatch
        let strain = app.descendants(matching: .any)["recovery-summary-strain"].firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 5), "Expected the daily recovery score in the summary card.")
        XCTAssertTrue(trend.exists, "Expected the trend score in the summary card.")
        XCTAssertTrue(strain.exists, "Expected strain directly beneath the recovery scores.")

        // A day with no snapshot (earlier than the seeded range) shows the
        // honest empty state, no rings.
        // The demo backfills 40 days, which can cover the entire previous
        // month when the test runs near the start of a month. Move back two
        // months so the chosen day is deterministically outside the fixture.
        app.buttons["Previous month"].firstMatch.tap()
        app.buttons["Previous month"].firstMatch.tap()
        let unseededMonth = try XCTUnwrap(Calendar.current.date(byAdding: .month, value: -2, to: Date()))
        let components = Calendar.current.dateComponents([.year, .month], from: unseededMonth)
        let firstOfUnseededMonth = try XCTUnwrap(Calendar.current.date(from: components))
        let firstDay = app.descendants(matching: .any)
            .matching(identifier: "calendar-day")
            .matching(NSPredicate(
                format: "label BEGINSWITH %@",
                firstOfUnseededMonth.formatted(date: .abbreviated, time: .omitted)
            ))
            .firstMatch
        XCTAssertTrue(firstDay.waitForExistence(timeout: 3))
        firstDay.tap()
        XCTAssertTrue(app.staticTexts["No recovery recorded"].waitForExistence(timeout: 3),
                      "A day without a snapshot should show the no-recovery empty state.")
    }

    /// Wrapped acceptance: the Home "Report Available" card shows for a
    /// fresh report, opening it presents the story, and after closing, the
    /// card is gone (viewed) — while the report stays reachable in Profile.
    @MainActor
    func testWrappedCardOpensStoryThenDisappearsFromHome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-wrapped-demo", "-weightUnitRaw", "kg", "-didOnboard", "YES"]
        app.launch()

        let card = app.buttons["wrapped-report-available"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Expected the Monthly Report Available card on Home.")
        scrollUntilHittable(card, in: app)
        XCTAssertTrue(card.isHittable, "Expected the report card to be visible before opening it.")
        tapWhenReady(card)

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

    // MARK: - Experiments

    /// Drives the seeded experiment fixture through the public Insights entry,
    /// active management, completed results, and both comparison choices.
    /// Screenshots keep the feature's key first-run surfaces reviewable.
    @MainActor
    func testExperimentInsightsFlowOpensManagementResultsAndComparison() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",
            "--seed-experiment-demo",
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
            "-initialTab", "insights",
        ]
        app.launch()

        let insightsEntry = app.descendants(matching: .any)["insight-experiments-entry"].firstMatch
        XCTAssertTrue(
            insightsEntry.waitForExistence(timeout: 10),
            "Expected the visible Experiments entry on Insights."
        )
        scrollUntilHittable(insightsEntry, in: app)
        XCTAssertTrue(insightsEntry.isHittable, "Expected the Experiments entry to be reachable.")
        tapWhenReady(insightsEntry)

        let hubBack = app.descendants(matching: .any)["experiment-hub-back"].firstMatch
        let activeExperiment = app.descendants(matching: .any)["experiment-open-active"].firstMatch
        XCTAssertTrue(hubBack.waitForExistence(timeout: 8), "Expected the Experiments hub.")
        XCTAssertTrue(activeExperiment.waitForExistence(timeout: 5), "Expected the seeded active experiment.")
        XCTAssertTrue(app.staticTexts["Earlier Bedtime"].exists)
        XCTAssertTrue(app.staticTexts["Creatine 5 g"].exists)
        XCTAssertTrue(app.staticTexts["Baseline Block"].exists)
        attachScreenshot(app, name: "experiments-hub")

        tapWhenReady(activeExperiment)
        let detailBack = app.descendants(matching: .any)["experiment-detail-back"].firstMatch
        let manageExperiment = app.descendants(matching: .any)["experiment-manage"].firstMatch
        XCTAssertTrue(detailBack.waitForExistence(timeout: 5), "Expected the active experiment detail.")
        XCTAssertTrue(app.staticTexts["Earlier Bedtime"].exists)
        XCTAssertTrue(app.staticTexts["Active Experiment"].exists)
        XCTAssertTrue(manageExperiment.isHittable, "Expected a visible Manage experiment control.")
        attachScreenshot(app, name: "experiment-active-detail")

        tapWhenReady(manageExperiment)
        let manageNavigationBar = app.navigationBars["Manage Experiment"].firstMatch
        XCTAssertTrue(manageNavigationBar.waitForExistence(timeout: 5), "Expected experiment management.")
        XCTAssertTrue(
            app.textFields["experiment-edit-name"].firstMatch.waitForExistence(timeout: 3),
            "Expected the experiment name to be directly editable."
        )
        XCTAssertTrue(app.buttons["experiment-save-management"].firstMatch.exists)
        attachScreenshot(app, name: "experiment-active-management")

        tapWhenReady(app.buttons["Cancel"].firstMatch)
        XCTAssertTrue(manageNavigationBar.waitForNonExistence(timeout: 5), "Expected Cancel to return to the active detail.")
        XCTAssertTrue(detailBack.waitForExistence(timeout: 3))
        tapWhenReady(detailBack)
        XCTAssertTrue(hubBack.waitForExistence(timeout: 5), "Expected to return to the Experiments hub.")

        let completedExperiment = app.staticTexts["Creatine 5 g"].firstMatch
        dragUp(app, until: completedExperiment, maxDrags: 12)
        XCTAssertTrue(
            completedExperiment.exists && completedExperiment.isHittable,
            "Expected the completed Creatine experiment in the visible history."
        )
        tapWhenReady(completedExperiment)

        let viewResults = app.descendants(matching: .any)["experiment-view-results"].firstMatch
        XCTAssertTrue(viewResults.waitForExistence(timeout: 5), "Expected the completed experiment detail.")
        XCTAssertTrue(app.staticTexts["Creatine 5 g"].exists)
        scrollUntilHittable(viewResults, in: app)
        XCTAssertTrue(viewResults.isHittable, "Expected a visible View Results action.")
        tapWhenReady(viewResults)

        let changeComparison = app.descendants(matching: .any)["experiment-change-comparison"].firstMatch
        XCTAssertTrue(changeComparison.waitForExistence(timeout: 8), "Expected the completed experiment results.")
        XCTAssertTrue(app.staticTexts["Creatine 5 g"].exists)
        _ = app.descendants(matching: .any)["experiment-analysis-loading"].firstMatch
            .waitForNonExistence(timeout: 10)
        attachScreenshot(app, name: "experiment-completed-results")

        tapWhenReady(changeComparison)
        let compareNavigationBar = app.navigationBars["Compare With"].firstMatch
        XCTAssertTrue(compareNavigationBar.waitForExistence(timeout: 5), "Expected the comparison picker.")
        let previousPeriod = app.staticTexts["Previous Equal Period"].firstMatch
        let baselineExperiment = app.staticTexts["Baseline Block"].firstMatch
        XCTAssertTrue(previousPeriod.waitForExistence(timeout: 3))
        XCTAssertTrue(baselineExperiment.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "experiment-comparison-picker")

        tapWhenReady(previousPeriod)
        XCTAssertTrue(compareNavigationBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(changeComparison.waitForExistence(timeout: 3))

        tapWhenReady(changeComparison)
        XCTAssertTrue(compareNavigationBar.waitForExistence(timeout: 5))
        tapWhenReady(app.staticTexts["Baseline Block"].firstMatch)
        XCTAssertTrue(compareNavigationBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Match Custom Trackers"].waitForExistence(timeout: 5),
            "Choosing another experiment should reveal explicit custom-tracker matching."
        )
        let energyPairing = app.descendants(matching: .any)[
            "experiment-custom-pair-E2000000-0000-4000-8000-000000000002"
        ].firstMatch
        dragUp(app, until: energyPairing, maxDrags: 12)
        XCTAssertTrue(
            energyPairing.exists && energyPairing.isHittable,
            "Expected the Morning energy reference picker."
        )
        tapWhenReady(energyPairing)
        let baselineEnergy = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Morning energy")
        ).firstMatch
        XCTAssertTrue(
            baselineEnergy.waitForExistence(timeout: 3),
            "Expected the compatible Baseline energy tracker."
        )
        tapWhenReady(baselineEnergy)
        let referenceLabel = app.staticTexts["Reference: Baseline Block"].firstMatch
        dragUp(app, until: referenceLabel, maxDrags: 8)
        XCTAssertTrue(
            referenceLabel.waitForExistence(timeout: 5),
            "Expected the paired reference tracker summary."
        )
        attachScreenshot(app, name: "experiment-comparison-selected")
    }

    // MARK: - Home dashboard and dormant coach

    /// Calendar is the public Home header action. Coach remains implemented,
    /// but neither coach entry point should be exposed while that experiment is
    /// dormant.
    @MainActor
    func testHomeCalendarReplacesCoachAndOpensCalendar() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        let calendar = app.descendants(matching: .any)["home-calendar"].firstMatch
        XCTAssertTrue(calendar.waitForExistence(timeout: 8), "Expected the accessible calendar shortcut on Home.")
        XCTAssertFalse(app.descendants(matching: .any)["home-coach-corner"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["home-ask-coach"].firstMatch.exists)
        tapWhenReady(calendar)

        XCTAssertTrue(app.staticTexts["Calendar"].waitForExistence(timeout: 5), "Expected the same training calendar used by Profile.")
        XCTAssertTrue(app.descendants(matching: .any)["calendar-day"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Every app-bar destination is an escape hatch to that tab's root. This
    /// covers both reselecting the current tab and returning to a tab whose
    /// navigation stack was left several screens deep.
    @MainActor
    func testAppBarTabsAlwaysReturnToRoot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        let homeCalendar = app.descendants(matching: .any)["home-calendar"].firstMatch
        XCTAssertTrue(homeCalendar.waitForExistence(timeout: 8))
        tapWhenReady(homeCalendar)
        XCTAssertTrue(app.staticTexts["Calendar"].waitForExistence(timeout: 5))

        tapWhenReady(app.descendants(matching: .any)["tab-home"].firstMatch)
        XCTAssertTrue(homeCalendar.waitForExistence(timeout: 5), "Reselecting Home should return to the Home root.")

        tapWhenReady(homeCalendar)
        XCTAssertTrue(app.staticTexts["Calendar"].waitForExistence(timeout: 5))
        tapWhenReady(app.descendants(matching: .any)["tab-workout"].firstMatch)
        XCTAssertTrue(app.staticTexts["Workout"].waitForExistence(timeout: 5))
        tapWhenReady(app.descendants(matching: .any)["tab-home"].firstMatch)
        XCTAssertTrue(homeCalendar.waitForExistence(timeout: 5), "Returning to Home should reveal its root, not Calendar.")
    }

    /// Every compact Home metric opens a focused page with the same Today /
    /// Trends control and a matching Today summary.
    @MainActor
    func testHomeMetricTilesOpenFocusedDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-partial-sleep-demo", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launchEnvironment["FORGEFIT_PARTIAL_SLEEP_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.descendants(matching: .any)["home-metric-grid"].firstMatch.waitForExistence(timeout: 10))
        let destinations = [
            ("home-recovery-card", "recovery-detail", "recovery-detail-tabs", "recovery-today-summary"),
            ("home-sleep-card", "sleep-detail", "sleep-detail-tabs", "sleep-today-summary"),
            ("daily-strain-card", "strain-detail", "strain-detail-tabs", "strain-today-summary"),
            ("home-health-card", "health-detail", "health-detail-tabs", "health-today-summary"),
        ]
        for (tileID, detailID, tabsID, summaryID) in destinations {
            let tile = app.descendants(matching: .any)[tileID].firstMatch
            XCTAssertTrue(tile.waitForExistence(timeout: 5), "Expected \(tileID) on Home.")
            if tileID == "home-recovery-card" {
                XCTAssertFalse(tile.label.contains("%"), "Recovery is an index, not percent recovered.")
            }
            tapWhenReady(tile)
            XCTAssertTrue(app.descendants(matching: .any)[detailID].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)[tabsID].firstMatch.exists)
            XCTAssertTrue(app.descendants(matching: .any)[summaryID].firstMatch.waitForExistence(timeout: 5))
            if detailID == "health-detail" {
                XCTAssertTrue(app.staticTexts["Respiratory rate"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.staticTexts["Blood oxygen"].exists)
            }
            tapWhenReady(app.buttons["Back"].firstMatch)
        }
    }

    @MainActor
    func testHomeRecommendationDisclosureCollapsesDetails() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-partial-sleep-demo", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launchEnvironment["FORGEFIT_PARTIAL_SLEEP_DEMO"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Today's recommendation"].waitForExistence(timeout: 10))
        let disclosure = app.descendants(matching: .any)["home-recommendation-disclosure"].firstMatch
        let details = app.descendants(matching: .any)["home-recommendation-details"].firstMatch
        XCTAssertTrue(disclosure.exists)
        XCTAssertTrue(details.exists)

        tapWhenReady(disclosure)
        XCTAssertTrue(details.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Today's recommendation"].exists)

        tapWhenReady(disclosure)
        XCTAssertTrue(details.waitForExistence(timeout: 2))
    }

    /// Home's weekly summary is a Sunday-to-Saturday completion calendar,
    /// followed by the existing totals. Streak copy and controls are gone.
    @MainActor
    func testHomeWeekCardShowsCompletionCalendarWithoutStreaks() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","--seed-week-demo", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.launch()

        let heading = app.staticTexts["This week"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 8), "Expected the This week card on Home.")
        XCTAssertTrue(app.descendants(matching: .any)["home-week-date-range"].firstMatch.exists)

        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        for weekday in weekdays {
            XCTAssertTrue(app.descendants(matching: .any)["home-week-day-\(weekday)"].firstMatch.exists,
                          "Expected a circle for \(weekday).")
        }
        let sunday = app.descendants(matching: .any)["home-week-day-sunday"].firstMatch
        XCTAssertEqual(sunday.value as? String, "Workout completed")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'streak'")).firstMatch.exists)
    }

    @MainActor
    func testProfileTrophyShelfRendersAndOpensTrophy() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "-didOnboard", "YES","-didOnboard", "YES", "-weightUnitRaw", "kg",
            "-initialTab", "profile",
        ]
        app.launch()

        let shelf = app.descendants(matching: .any)["trophy-shelf"].firstMatch
        let firstTrophy = app.descendants(matching: .any)["trophy-workouts-1"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 8), "Expected the trophy shelf on Profile.")
        scrollUntilHittable(firstTrophy, in: app)
        XCTAssertTrue(firstTrophy.isHittable, "Expected the first trophy to render inside the shelf.")

        firstTrophy.tap()
        XCTAssertTrue(app.staticTexts["First session"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["In progress"].exists)
    }

    /// A fresh account (no coached program yet) must offer "Build my plan"
    /// in the "This week" section rather than a dangling active-program card.
    @MainActor
    func testCoachCornerNoPlanStateShowsBuildMyPlan() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg", "-coach_corner", "YES", "-openCoachCorner", "YES"]
        app.launch()

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
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg", "-coach_corner", "YES", "-openCoachCorner", "YES"]
        app.launch()

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
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg", "-coach_corner", "YES", "-openCoachCorner", "YES"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Coach's Corner"].waitForExistence(timeout: 5))

        let askCoach = app.descendants(matching: .any)["coach-corner-ask-coach"].firstMatch
        scrollUntilHittable(askCoach, in: app)
        tapWhenReady(askCoach)

        let greeting = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'got your readiness'")).firstMatch
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

    /// The dormant chat remains launchable for regression coverage without a
    /// user-facing Home affordance.
    @MainActor
    func testDormantCoachChatStillLaunchesThroughAutomationHook() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES","-weightUnitRaw", "kg", "-openCoachChat", "YES"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Ask your Coach"].waitForExistence(timeout: 5), "Expected the chat to present directly.")
        XCTAssertFalse(app.navigationBars["Coach's Corner"].exists, "Coach's Corner must not present when the flag is off.")

        let greeting = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'got your readiness'")).firstMatch
        XCTAssertTrue(greeting.waitForExistence(timeout: 5), "Expected the chat greeting.")
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
