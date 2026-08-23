import XCTest

/// History → Edit workout → cardio metrics stay editable after the fact.
/// The treadmill flow: the watch recorded time and heart rate, the machine
/// knew the distance — the user adds it days later from history. Decimal
/// entry must survive typing ("5.2" must not collapse into "52").
final class CardioHistoryEditUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func savedDistanceOracle(_ app: XCUIApplication, id: String) -> AcceptanceOracle {
        AcceptanceOracle(id: id) {
            let readout = app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS '5.2'"))
                .firstMatch
            let passed = readout.exists && readout.label.contains("5.2")
            return AcceptanceOracleResult(
                id: id,
                outcome: passed ? .pass : .fail,
                message: passed
                    ? "The saved cardio distance readout contains 5.2."
                    : "The saved cardio distance readout was not visible after the action."
            )
        }
    }

    @MainActor
    func testAddDistanceToPastTreadmillRun() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--seed-history", "-didOnboard", "YES",
            "-weightUnitRaw", "kg", "-initialTab", "profile", "-quickActionBubble.v1", "",
        ]
        app.acceptanceLaunch()

        let profileReceipt = element(app, "profile-exercises")
        try acceptanceSetup("seeded profile readiness") {
            guard profileReceipt.waitForExistence(timeout: 45) else {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "cardio-history-launch-failure"
                screenshot.lifetime = .keepAlways
                XCTContext.runActivity(named: "Capture launch failure") { activity in
                    activity.add(screenshot)
                    let tree = XCTAttachment(string: app.debugDescription)
                    tree.name = "cardio-history-launch-accessibility"
                    tree.lifetime = .keepAlways
                    activity.add(tree)
                }
                throw XCTSkip("Expected the seeded Profile dashboard after deterministic launch data completed.")
            }
        }

        // Profile → History. "See all" sits in the Workouts section header,
        // which remains off-screen until the lazy profile content is scrolled.
        // `--reset-store --seed-history` deliberately rebuilds the complete
        // exercise catalog plus 120 sessions before applying `initialTab`.
        // When a preceding UI run leaves a live workout in the store, Home
        // can render that stale pre-reset snapshot while the MainActor seed is
        // still working. Profile is the post-seed receipt; never start blind
        // swipes against the temporary Home tree.
        XCTAssertTrue(
            app.staticTexts["Profile"].firstMatch.waitForExistence(timeout: 45),
            "Expected the seeded profile after launch reset completed."
        )
        let seeAll = element(app, "profile-see-all-workouts")
        var swipes = 0
        while !(seeAll.exists && seeAll.isHittable), swipes < 14 {
            app.acceptanceSwipeUp()
            swipes += 1
        }
        XCTAssertTrue(seeAll.isHittable, "Expected the profile workout list.")
        seeAll.acceptanceTap()

        let search = element(app, "history-search-field")
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Expected the history search field.")
        search.acceptanceTap()
        search.acceptanceTypeText("morning run #117")

        let row = element(app, "history-workout-Morning Run #117")
        if !row.waitForExistence(timeout: 8) {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "cardio-history-missing-seeded-row"
            screenshot.lifetime = .keepAlways
            XCTContext.runActivity(named: "Capture missing seeded history row") { activity in
                activity.add(screenshot)
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "cardio-history-missing-seeded-row-accessibility"
                tree.lifetime = .keepAlways
                activity.add(tree)
            }
            XCTFail("Expected the seeded run in history results.")
            return
        }
        row.acceptanceTap()

        // Detail → Edit workout opens the historical editor.
        let edit = app.buttons["Edit workout"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 8), "Expected the workout detail edit button.")
        edit.acceptanceTap()

        // The cardio card offers Edit in history mode now.
        let cardioEdit = element(app, "cardio-history-edit")
        XCTAssertTrue(cardioEdit.waitForExistence(timeout: 8), "Expected the editable cardio card.")
        if !cardioEdit.isHittable { app.acceptanceSwipeUp() }
        cardioEdit.acceptanceTap()

        let distance = element(app, "cardio-field-distance")
        XCTAssertTrue(distance.waitForExistence(timeout: 5), "Expected the distance field.")
        distance.acceptanceTap()
        distance.acceptanceTypeText("5.2")
        XCTAssertEqual(distance.value as? String, "5.2", "Decimal entry must survive typing.")

        // Done → the readout shows the added distance.
        acceptanceExpect(
            invariants: ["saved-cardio-distance-is-visible"],
            oracles: [savedDistanceOracle(app, id: "saved-cardio-distance-is-visible")]
        )
        cardioEdit.acceptanceTap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5.2'")).firstMatch.waitForExistence(timeout: 5),
            "Expected the distance readout after editing."
        )

        // Close and reopen the editor — the edit persisted.
        app.buttons["Close editor"].firstMatch.acceptanceTap()
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        acceptanceExpect(
            invariants: ["saved-cardio-distance-survives-reopen"],
            oracles: [savedDistanceOracle(app, id: "saved-cardio-distance-survives-reopen")]
        )
        edit.acceptanceTap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5.2'")).firstMatch.waitForExistence(timeout: 8),
            "Expected the added distance to persist across editor sessions."
        )
    }
}
