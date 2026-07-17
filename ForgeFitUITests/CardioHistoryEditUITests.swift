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

    @MainActor
    func testAddDistanceToPastTreadmillRun() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "--seed-history", "-didOnboard", "YES",
            "-weightUnitRaw", "kg", "-initialTab", "profile", "-quickActionBubble.v1", "",
        ]
        app.launch()

        // Profile → History. "See all workouts" sits at the bottom of a lazy
        // list — off-screen rows aren't in the hierarchy until scrolled to.
        _ = app.staticTexts["Profile"].firstMatch.waitForExistence(timeout: 15)
        let seeAll = app.staticTexts["See all workouts"].firstMatch
        var swipes = 0
        while !(seeAll.exists && seeAll.isHittable), swipes < 14 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(seeAll.isHittable, "Expected the profile workout list.")
        seeAll.tap()

        let search = element(app, "history-search-field")
        XCTAssertTrue(search.waitForExistence(timeout: 8), "Expected the history search field.")
        search.tap()
        search.typeText("morning run #117")

        let row = element(app, "history-workout-Morning Run #117")
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Expected the seeded run in history results.")
        row.tap()

        // Detail → Edit workout opens the historical editor.
        let edit = app.buttons["Edit workout"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 8), "Expected the workout detail edit button.")
        edit.tap()

        // The cardio card offers Edit in history mode now.
        let cardioEdit = element(app, "cardio-history-edit")
        XCTAssertTrue(cardioEdit.waitForExistence(timeout: 8), "Expected the editable cardio card.")
        if !cardioEdit.isHittable { app.swipeUp() }
        cardioEdit.tap()

        let distance = element(app, "cardio-field-distance")
        XCTAssertTrue(distance.waitForExistence(timeout: 5), "Expected the distance field.")
        distance.tap()
        distance.typeText("5.2")
        XCTAssertEqual(distance.value as? String, "5.2", "Decimal entry must survive typing.")

        // Done → the readout shows the added distance.
        cardioEdit.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5.2'")).firstMatch.waitForExistence(timeout: 5),
            "Expected the distance readout after editing."
        )

        // Close and reopen the editor — the edit persisted.
        app.buttons["Close editor"].firstMatch.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 8))
        edit.tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '5.2'")).firstMatch.waitForExistence(timeout: 8),
            "Expected the added distance to persist across editor sessions."
        )
    }
}
