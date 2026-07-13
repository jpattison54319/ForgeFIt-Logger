import XCTest

/// End-to-end drive of the social feature against the seeded `MockSocialBackend`
/// (launch arg `--mock-social`), which needs no iCloud account. Exercises:
/// Profile → Community → opt-in → seeded friends → visit a friend's profile.
final class SocialUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        element.tap()
    }

    @MainActor
    func testOptInThenVisitFriendProfile() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "--mock-social", "-didOnboard", "YES", "-weightUnitRaw", "lb"]
        app.launch()

        // Profile tab → Community tile.
        let profileTab = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15), "Expected the Profile tab.")
        tapWhenReady(profileTab)

        let community = app.descendants(matching: .any)["dashboard-community"].firstMatch
        var scrolls = 0
        while !community.isHittable, scrolls < 6 { app.swipeUp(velocity: .fast); scrolls += 1 }
        XCTAssertTrue(community.waitForExistence(timeout: 5), "Expected the Community dashboard tile.")
        tapWhenReady(community)

        // Community starts at the opt-in gate.
        let enable = app.descendants(matching: .any)["social-enable"].firstMatch
        XCTAssertTrue(enable.waitForExistence(timeout: 8), "Community should show the opt-in gate before opting in.")
        tapWhenReady(enable)

        // Opt-in sheet: claim a handle, then confirm once it validates.
        let handleField = app.textFields["social-handle-field"].firstMatch
        XCTAssertTrue(handleField.waitForExistence(timeout: 8), "Expected the opt-in handle field.")
        tapWhenReady(handleField)
        handleField.typeText("demoathlete")

        let confirm = app.descendants(matching: .any)["social-optin-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // Wait for the async availability check to enable the button.
        let deadline = Date().addingTimeInterval(8)
        while !confirm.isEnabled, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertTrue(confirm.isEnabled, "Enable should activate once the handle checks out as available.")
        tapWhenReady(confirm)

        // Back on Community, opted in: the seeded friends appear.
        let alex = app.staticTexts["Alex Rivera"].firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: 10), "Seeded friend 'Alex Rivera' should appear in the friends list after opting in.")
        XCTAssertTrue(app.staticTexts["Leaderboards"].firstMatch.waitForExistence(timeout: 3), "Leaderboards entry should be present.")

        // Visit the friend's profile → their shared workout is listed.
        tapWhenReady(alex)
        let handle = app.staticTexts["@alexlifts"].firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 8), "The friend's profile header (@alexlifts) should render.")
        XCTAssertTrue(app.staticTexts["Push Day A"].firstMatch.waitForExistence(timeout: 5), "The friend's shared workout 'Push Day A' should be listed.")
    }
}
