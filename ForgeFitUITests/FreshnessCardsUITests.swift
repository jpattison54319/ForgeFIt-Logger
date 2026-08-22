import XCTest

final class FreshnessCardsUITests: XCTestCase {
    @MainActor
    func testFreshnessCardsExposeBodyRegionsAndKeepCardioConcise() {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--skip-onboarding",
            "--seed-appstore-demo",
            "--seed-recovery-demo",
            "-didOnboard", "YES",
        ]
        app.acceptanceLaunch()

        XCTAssertTrue(app.buttons["tab-home"].firstMatch.waitForExistence(timeout: 60))
        for _ in 0..<2 where app.buttons["onboarding-get-started"].firstMatch.exists {
            app.acceptanceTerminate()
            app.acceptanceLaunch()
            XCTAssertTrue(app.buttons["tab-home"].firstMatch.waitForExistence(timeout: 60))
        }
        XCTAssertFalse(app.buttons["onboarding-get-started"].firstMatch.exists)

        let recovery = app.descendants(matching: .any)["home-recovery-card"].firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 60))
        recovery.acceptanceTap()

        let trends = app.buttons["Trends"].firstMatch
        XCTAssertTrue(trends.waitForExistence(timeout: 10))
        trends.acceptanceTap()

        let legs = app.buttons["muscle-freshness-toggle-legs"].firstMatch
        scrollUntilVisible(legs, in: app)
        XCTAssertTrue(legs.exists)
        legs.acceptanceTap()
        XCTAssertTrue(app.staticTexts["Quadriceps"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Calves"].exists)

        let core = app.buttons["muscle-freshness-toggle-core"].firstMatch
        scrollUntilVisible(core, in: app)
        XCTAssertTrue(core.exists)
        core.acceptanceTap()
        XCTAssertTrue(app.staticTexts["Abs"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Obliques"].exists)

        scrollUntilVisible(app.staticTexts["Cardio freshness"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Cardio freshness"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'provisional'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'remaining modeled exposure'")).firstMatch.exists)
    }

    @MainActor
    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            app.acceptanceSwipeUp()
        }
    }
}
