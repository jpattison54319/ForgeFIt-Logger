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
        let lowerRoutine = app.staticTexts["Routine B, Lower, remaining"].firstMatch
        try acceptanceRequire(
            movedRestRow.exists && lowerRoutine.exists,
            "Expected the planned rest row and Lower routine as drag endpoints."
        )
        acceptanceExpect(
            visibleLabels: [
                "Rest Day Options",
                "Rest Day",
                "Routine A, Upper, remaining",
                "Routine B, Lower, remaining",
            ],
            invariants: ["Holding and dragging the rest row previews it snapping between fixed folder-ordered workouts before the drop commits."]
        )
        movedRestRow.acceptancePress(forDuration: 0.8, thenDragTo: lowerRoutine)

        acceptanceAssert(
            movedRestRow.waitForExistence(timeout: 3)
                && (movedRestRow.value as? String) == "Position 2 of 3",
            "Expected the rest slot to move above Lower while Upper remained first."
        )

        let restOptions = app.buttons["Rest day options"].firstMatch
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
