import XCTest

final class PersistenceRecoveryUITests: XCTestCase {
    @MainActor
    func testUnreadableStoreShowsPreservingRecoveryPathInsteadOfCrashing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--simulate-persistence-failure"]
        app.launch()

        let title = app.staticTexts["ForgeFit couldn't open your data"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Do not delete or reinstall ForgeFit while your history is unavailable."].exists)
        XCTAssertTrue(app.buttons["persistence-retry"].isHittable)
        XCTAssertEqual(app.staticTexts["persistence-support-code"].label, "Support code: DATA-OPEN-1")
    }
}
