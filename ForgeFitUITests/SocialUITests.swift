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

    /// Scrolls the element into view (friends sit below the profile card /
    /// action rows) then taps it.
    private func scrollToTap(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), "expected element to exist before scrolling")
        var swipes = 0
        while !element.isHittable, swipes < maxSwipes { app.swipeUp(velocity: .fast); swipes += 1 }
        tapWhenReady(element)
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

        // Visit the strength friend → their shared workout is listed.
        scrollToTap(alex, in: app)
        XCTAssertTrue(app.staticTexts["@alexlifts"].firstMatch.waitForExistence(timeout: 8), "The friend's profile header (@alexlifts) should render.")
        XCTAssertTrue(app.staticTexts["Push Day A"].firstMatch.waitForExistence(timeout: 5), "The strength workout 'Push Day A' should be listed.")

        // Back, visit the runner → a CARDIO workout renders (health + GPS stripped).
        tapWhenReady(app.buttons["Back"].firstMatch)
        scrollToTap(app.staticTexts["Mia Chen"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Tempo Run"].firstMatch.waitForExistence(timeout: 8), "Mia's cardio workout 'Tempo Run' should render.")

        // Back, visit the yogi → a YOGA workout renders.
        tapWhenReady(app.buttons["Back"].firstMatch)
        scrollToTap(app.staticTexts["Sam Okafor"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Vinyasa Flow"].firstMatch.waitForExistence(timeout: 8), "Sam's yoga workout 'Vinyasa Flow' should render.")
    }
}
