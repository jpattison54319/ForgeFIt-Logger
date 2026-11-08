import XCTest

final class MicrocycleTrackingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testProfileGroupsSeparateRunsAndOpensReadOnlyCycleDetail() {
        let app = launch(initialTab: "profile")

        let history = app.buttons["profile-microcycle-history"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.acceptanceTap()

        XCTAssertTrue(app.navigationBars["Microcycle History"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(
            NSPredicate(format: "label == 'Strength Cycle'")
        ).count, 2)
        XCTAssertTrue(app.staticTexts["TRACKING"].exists)
        XCTAssertTrue(app.staticTexts["STOPPED"].exists)

        let window = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'microcycle-history-window-'")
        ).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Workouts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["microcycle-log-rest-day"].exists)
        XCTAssertFalse(app.buttons["microcycle-remove-day-backfill"].exists)
    }

    @MainActor
    func testMakingMicrocycleActiveOffersTrackingAndExplainsDayTarget() {
        let app = launch(initialTab: "workout")
        let options = app.buttons["Folder options for Conditioning Cycle"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.acceptanceTap()

        let activate = app.buttons["Set as Active Microcycle"].firstMatch
        XCTAssertTrue(activate.waitForExistence(timeout: 3))
        activate.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Track \"Conditioning Cycle\"?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'calendar days each cycle lasts'")
        ).firstMatch.exists)
        let target = app.buttons["Set Day Target"].firstMatch
        XCTAssertTrue(target.exists)
        target.acceptanceTap()

        XCTAssertTrue(app.navigationBars["Conditioning Cycle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Each cycle lasts this many calendar days before the next one begins."].exists)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Starting this tracker stops Strength Cycle'")
        ).firstMatch.exists)
    }

    @MainActor
    func testPreviousWindowInLiveTrackerOpensReadOnlyDetail() {
        let app = launch(initialTab: "workout")
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.acceptanceTap()

        let previous = app.buttons["microcycle-previous-window-1"].firstMatch
        scrollToHittable(previous, in: app)
        previous.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Workouts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["microcycle-log-rest-day"].exists)
        XCTAssertFalse(app.buttons["stop-microcycle-tracking"].exists)
    }

    @MainActor
    func testPreviousCyclesProgressivelyDiscloseFullHistory() throws {
        let app = launch(initialTab: "workout", additionalArguments: ["--seed-microcycle-long-history"])
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        try acceptanceRequire(progress.waitForExistence(timeout: 10), "Expected the active tracker.")
        acceptanceExpect(visibleLabels: ["Current window"], invariants: ["Only the latest three of 43 previous cycles appear on the detail screen."])
        progress.acceptanceTap()
        let all = app.buttons["microcycle-view-all-previous-cycles"]
        scrollToHittable(all, in: app)
        acceptanceAssert(all.frame.height >= 44, "View All must expose a 44-point touch target.")
        acceptanceAssert(app.buttons["microcycle-previous-window-43"].exists, "Expected newest cycle in preview.")
        acceptanceAssert(!app.buttons["microcycle-previous-window-40"].exists, "Older cycles must stay outside the preview.")
        acceptanceExpect(visibleLabels: ["Previous Cycles", "Page 1", "Older"], invariants: ["The full browser starts with at most twenty previous cycles."])
        all.acceptanceTap()
        let older = app.buttons["microcycle-history-older"]
        try acceptanceRequire(older.waitForExistence(timeout: 5), "Expected visible paging controls.")
        acceptanceAssert(older.frame.height >= 44, "Older must expose a 44-point touch target.")
        acceptanceAssert(app.buttons["microcycle-history-newer"].frame.height >= 44, "Newer must expose a 44-point touch target.")
        acceptanceAssert(!app.buttons["microcycle-history-newer"].isEnabled, "Newest page has no newer page.")
        acceptanceExpect(visibleLabels: ["Page 2", "Cycle 23"], invariants: ["Older advances to the next bounded page."])
        older.acceptanceTap()
        acceptanceAssert(app.staticTexts["Page 2"].waitForExistence(timeout: 5), "Expected second page.")
        acceptanceExpect(visibleLabels: ["Page 3", "Cycle 1"], invariants: ["The final page preserves access to the oldest cycle."])
        older.acceptanceTap()
        acceptanceAssert(app.staticTexts["Page 3"].waitForExistence(timeout: 5), "Expected final page.")
        acceptanceAssert(!older.isEnabled, "Final page cannot advance beyond history.")
        let oldest = app.buttons["microcycle-previous-window-1"]
        try acceptanceRequire(oldest.waitForExistence(timeout: 5), "Expected the oldest cycle.")
        acceptanceExpect(visibleLabels: ["Workouts"], invariants: ["Oldest cycle opens the existing read-only detail."])
        oldest.acceptanceTap()
        acceptanceAssert(app.staticTexts["Workouts"].waitForExistence(timeout: 5), "Expected full cycle detail.")
        acceptanceAssert(!app.buttons["microcycle-log-rest-day"].exists, "Historical cycles remain read-only.")
        acceptanceExpect(visibleLabels: ["Page 3"], invariants: ["Back preserves the browser page."])
        app.navigationBars.buttons.firstMatch.acceptanceTap()
        acceptanceAssert(app.staticTexts["Page 3"].waitForExistence(timeout: 5), "Expected preserved page.")
        acceptanceExpect(visibleLabels: ["Page 2"], invariants: ["Newer returns to the preceding page."])
        app.buttons["microcycle-history-newer"].acceptanceTap()
        acceptanceAssert(app.staticTexts["Page 2"].waitForExistence(timeout: 5), "Expected newer page.")
    }

    @MainActor
    func testAlternatedRoutineActionNamesItsCyclicSuccessor() throws {
        let app = launch(
            initialTab: "workout",
            additionalArguments: ["--seed-microcycle-tracking-alternation"]
        )
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        try acceptanceRequire(
            progress.waitForExistence(timeout: 10),
            "Expected the seeded tracked microcycle entry point."
        )
        acceptanceExpect(
            visibleLabels: ["Start Upper", "Start Lower"],
            invariants: [
                "The compact alternate action names Lower, the immediate cyclic successor of the due Upper routine."
            ]
        )
        progress.acceptanceTap()

        let successor = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'microcycle-start-next-'")
        ).firstMatch
        try acceptanceRequire(
            successor.waitForExistence(timeout: 5),
            "Expected the tracked alternating routine to expose its cyclic successor."
        )
        let due = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'microcycle-start-routine-'")
        ).firstMatch
        acceptanceAssert(
            due.label == "Start Upper",
            "Expected the primary action to announce the due Upper routine."
        )
        acceptanceAssert(
            successor.label == "Start Lower",
            "Expected the alternate action to name Lower instead of using generic next copy."
        )
        acceptanceAssert(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH[c] 'Start Next'")
            ).count == 0,
            "Expected no generic Start Next action in the tracked microcycle."
        )
    }

    @MainActor
    func testFirstStopExplainsHistoryAndOpensItFromProfile() {
        let app = launch(
            initialTab: "workout",
            additionalArguments: ["-microcycleHistoryEducationShown", "NO"]
        )
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        progress.acceptanceTap()

        let stop = app.buttons["stop-microcycle-tracking"].firstMatch
        scrollToHittable(stop, in: app)
        stop.acceptanceTap()
        let confirm = app.buttons["Stop Tracking"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Microcycle history saved"].waitForExistence(timeout: 5))
        let viewHistory = app.buttons["View History"].firstMatch
        XCTAssertTrue(viewHistory.waitForExistence(timeout: 3))
        viewHistory.acceptanceTap()

        XCTAssertTrue(app.navigationBars["Microcycle History"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars["Microcycle History"].exists)
    }

    @MainActor
    func testAddsReordersAndLogsAPlannedRestDayWhileKeepingAdHocLogging() throws {
        let app = launch(
            initialTab: "workout",
            launchExpectedIdentifiers: ["microcycle-folder-progress"]
        )
        let progress = app.descendants(matching: .any)["microcycle-folder-progress"].firstMatch
        try acceptanceRequire(
            progress.waitForExistence(timeout: 10),
            "Expected the seeded tracked microcycle entry point."
        )
        acceptanceExpect(
            ["microcycle-rest-day-menu"],
            visibleLabels: ["Rest Day Options"],
            invariants: ["The tracked view keeps folder routines visible and exposes rest actions as one menu."]
        )
        progress.acceptanceTap()

        let restMenu = app.buttons["microcycle-rest-day-menu"].firstMatch
        scrollToHittable(restMenu, in: app)
        acceptanceExpect(
            visibleLabels: ["Log Rest Day Ad Hoc", "Add Rest Day to Routine"],
            invariants: ["The existing ad-hoc action remains available beside the new planned-rest action."]
        )
        restMenu.acceptanceTap()

        let addToRoutine = app.buttons["Add Rest Day to Routine"].firstMatch
        try acceptanceRequire(
            addToRoutine.waitForExistence(timeout: 3),
            "Expected the planned-rest menu action."
        )
        acceptanceExpect(
            visibleLabels: ["Rest Day Options"],
            invariants: ["The add action closes its menu; the planned slot is asserted after the SwiftData query refreshes."]
        )
        addToRoutine.acceptanceTap()

        try acceptanceRequire(
            app.staticTexts["Planned"].waitForExistence(timeout: 5),
            "Expected the new planned rest row to render."
        )
        let logPlanned = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'microcycle-log-planned-rest-'")
        ).firstMatch
        let upperStart = app.buttons["Start Upper"].firstMatch
        try acceptanceRequire(
            logPlanned.waitForExistence(timeout: 3) && upperStart.exists,
            "Expected compact Log and Start actions."
        )
        acceptanceAssert(
            abs(logPlanned.frame.width - upperStart.frame.width) <= 1
                && abs(logPlanned.frame.height - upperStart.frame.height) <= 1,
            "Expected Log and Start to use the same compact button footprint."
        )
        let movedRestRow = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'planned-rest-title-'")
        ).firstMatch
        let upperRoutine = app.staticTexts["Routine A, Upper, remaining"].firstMatch
        let lowerRoutine = app.staticTexts["Routine B, Lower, remaining"].firstMatch
        let reorderHandle = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'planned-rest-reorder-'")
        ).firstMatch
        let restOptions = app.buttons["Rest day options"].firstMatch
        scrollToHittable(reorderHandle, in: app)
        try acceptanceRequire(
            reorderHandle.isHittable && upperRoutine.isHittable && lowerRoutine.isHittable && movedRestRow.exists,
            "Expected the rest-day handle and both routine rows on screen."
        )
        acceptanceAssert(
            abs(movedRestRow.frame.minX - upperRoutine.frame.minX) <= 1
                && abs(movedRestRow.frame.minX - lowerRoutine.frame.minX) <= 1,
            "Expected the planned rest title to align with both routine titles."
        )
        acceptanceExpect(
            visibleLabels: [
                "Rest Day Options",
                "Rest Day",
                "Routine A, Upper, remaining",
                "Routine B, Lower, remaining",
            ],
            invariants: ["Dropping in the gap between workouts moves the rest day into that slot."]
        )
        let handle = reorderHandle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let gapY = (upperRoutine.frame.midY + lowerRoutine.frame.midY) / 2
        handle.acceptancePress(
            forDuration: 0.8,
            thenDragTo: app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: lowerRoutine.frame.midX, dy: gapY)
            )
        )

        acceptanceAssert(
            movedRestRow.waitForExistence(timeout: 3)
                && (movedRestRow.value as? String) == "Position 2 of 3",
            "Expected the rest slot to move above Lower while Upper remained first."
        )

        let back = app.navigationBars.firstMatch.buttons["BackButton"]
        try acceptanceRequire(back.isHittable, "Expected a way back to the workout tab.")
        acceptanceExpect(["microcycle-folder-progress"])
        back.acceptanceTap()
        try acceptanceRequire(progress.waitForExistence(timeout: 5), "Expected the tracked microcycle entry point.")
        acceptanceExpect(["microcycle-rest-day-menu"], visibleLabels: ["Rest Day"])
        progress.acceptanceTap()
        acceptanceAssert(
            movedRestRow.waitForExistence(timeout: 3)
                && (movedRestRow.value as? String) == "Position 2 of 3"
                && upperRoutine.frame.midY < movedRestRow.frame.midY
                && movedRestRow.frame.midY < lowerRoutine.frame.midY,
            "Reopening the microcycle should show the saved rest slot between the same workouts."
        )

        scrollToHittable(restOptions, in: app)
        try acceptanceRequire(
            restOptions.exists && restOptions.isHittable,
            "Expected visible options for the planned rest slot."
        )
        acceptanceExpect(
            visibleLabels: ["Move Up", "Move Down", "Remove Rest Day"],
            invariants: ["A rest slot between workouts can move in either direction without changing folder workout order."]
        )
        restOptions.acceptanceTap()
        acceptanceExpect(
            visibleLabels: ["Rest Day Options", "Rest Day"],
            invariants: ["Dismissing rest-slot options leaves the injected sequence unchanged."]
        )
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.20)).acceptanceTap()

        try acceptanceRequire(
            logPlanned.waitForExistence(timeout: 3),
            "Expected the planned rest logging action."
        )
        acceptanceExpect(
            visibleLabels: [
                "Log today as a rest day?",
                "This marks today as rest and completes this planned rest slot.",
                "Log Rest Day",
                "Cancel",
            ],
            invariants: ["Tapping Log asks for confirmation before changing the planned slot or calendar rest state."]
        )
        logPlanned.acceptanceTap()

        let cancelLog = app.buttons["Cancel"].firstMatch
        try acceptanceRequire(
            cancelLog.waitForExistence(timeout: 3),
            "Expected a cancel action in the planned-rest confirmation."
        )
        acceptanceExpect(
            visibleLabels: ["Rest Day", "Planned", "0/3"],
            invariants: ["Cancel leaves today unlogged and the selected rest slot planned."]
        )
        cancelLog.acceptanceTap()
        acceptanceAssert(
            app.staticTexts["Planned"].waitForExistence(timeout: 3) && app.staticTexts["0/3"].exists,
            "Expected cancel to leave the planned rest slot incomplete."
        )

        acceptanceExpect(
            visibleLabels: ["Log today as a rest day?", "Log Rest Day", "Cancel"],
            invariants: ["Reopening the confirmation still requires an explicit logging choice."]
        )
        logPlanned.acceptanceTap()
        let confirmLog = app.buttons["Log Rest Day"].firstMatch
        try acceptanceRequire(
            confirmLog.waitForExistence(timeout: 3),
            "Expected the explicit planned-rest confirmation action."
        )
        acceptanceExpect(
            visibleLabels: ["Rest Day Options", "Rest Day", "1/3"],
            invariants: ["Confirming logs calendar rest and completes exactly the selected planned slot without creating a workout."]
        )
        confirmLog.acceptanceTap()

        acceptanceAssert(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Logged '")).firstMatch
                .waitForExistence(timeout: 5),
            "Expected the planned rest row to show its logged state."
        )
        acceptanceAssert(app.staticTexts["1/3"].exists, "Expected rest to count as one planned item, not a workout.")
        acceptanceAssert(
            abs(movedRestRow.frame.minX - upperRoutine.frame.minX) <= 1,
            "Expected the logged rest title to stay aligned with the routine titles."
        )

        scrollToHittable(restMenu, in: app)
        acceptanceExpect(
            visibleLabels: ["Log Rest Day Ad Hoc", "Add Rest Day to Routine"],
            invariants: ["Logging planned rest does not remove the separate ad-hoc entry point."]
        )
        restMenu.acceptanceTap()
        let adHoc = app.buttons["Log Rest Day Ad Hoc"].firstMatch
        try acceptanceRequire(adHoc.waitForExistence(timeout: 3), "Expected ad-hoc rest logging to remain available.")
        acceptanceExpect(
            visibleLabels: ["Log Rest Day", "Cancel"],
            invariants: ["The ad-hoc action still opens the date-based rest logging sheet."]
        )
        adHoc.acceptanceTap()
        XCTAssertTrue(app.navigationBars["Log Rest Day"].waitForExistence(timeout: 3))
    }

    @MainActor
    private func launch(
        initialTab: String,
        additionalArguments: [String] = [],
        launchExpectedIdentifiers: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--seed-microcycle-tracking",
            "-didOnboard", "YES",
            "-initialTab", initialTab,
            "-weightUnitRaw", "kg",
        ] + additionalArguments
        if !launchExpectedIdentifiers.isEmpty {
            acceptanceExpect(
                launchExpectedIdentifiers,
                invariants: ["The seeded microcycle entry point is available after launch."]
            )
        }
        app.acceptanceLaunch()
        return app
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 8
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            app.acceptanceSwipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
