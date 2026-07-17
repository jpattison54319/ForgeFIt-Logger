import XCTest

/// The Home dashboard's same-day optimistic cache. HealthKit refreshes are
/// suppressed in both tests, freezing the app in its cold-launch pre-refresh
/// state — exactly the window where the cache (or the loader) must show.
final class HomeDashboardCacheUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Today already produced a render → reopening paints real numbers
    /// immediately: no "Loading" tiles, recommendation intact. Workout history
    /// is seeded deliberately: with workouts present the PRE-refresh strain
    /// engine returns a real 0.0 (zero training load, no movement data yet)
    /// rather than nil, and an ungated recording pass would stomp the day's
    /// cached strain with it on every cold launch.
    @MainActor
    func testTodaysCachedScoresPaintWhileRefreshIsInFlight() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",
            "--seed-history",
            "--suppress-health-refresh",
            "--seed-home-dashboard-cache",
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        let grid = app.descendants(matching: .any)["home-metric-grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 15), "Expected the Home metric grid.")

        let recoveryCard = app.descendants(matching: .any)["home-recovery-card"].firstMatch
        XCTAssertTrue(recoveryCard.waitForExistence(timeout: 5))
        XCTAssertTrue(recoveryCard.label.contains("82"),
                      "The cached recovery score should paint instantly, got: \(recoveryCard.label)")
        let strainCard = app.descendants(matching: .any)["daily-strain-card"].firstMatch
        XCTAssertTrue(strainCard.waitForExistence(timeout: 5))
        XCTAssertTrue(strainCard.label.contains("5.1"),
                      "The cached strain score should paint instantly and never be stomped to 0 by a pre-refresh pass, got: \(strainCard.label)")
        XCTAssertTrue(app.staticTexts["7h 12m"].waitForExistence(timeout: 5),
                      "The cached sleep duration should paint instantly.")
        XCTAssertTrue(app.staticTexts["All in range"].exists,
                      "The cached health headline should paint instantly.")
        XCTAssertTrue(app.staticTexts["Green light. Push intensity or volume today."].exists,
                      "The cached recommendation should paint instantly.")
        XCTAssertFalse(app.staticTexts["Syncing today's data"].exists,
                       "A day with a cached render must not show the loading tiles.")
        XCTAssertFalse(app.staticTexts["Crunching the numbers..."].exists,
                       "A day with a cached render must not show the recommendation loader.")
    }

    /// Only YESTERDAY has a cached render → first open of the new day shows
    /// the loader. A new day's scores don't exist yet, and an older day's must
    /// never stand in for them.
    @MainActor
    func testFirstOpenOfANewDayShowsLoaderNeverYesterday() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--suppress-health-refresh",
            "--seed-yesterday-dashboard-cache",
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        let grid = app.descendants(matching: .any)["home-metric-grid"].firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 10), "Expected the Home metric grid.")

        XCTAssertTrue(app.staticTexts["Syncing today's data"].firstMatch.waitForExistence(timeout: 5),
                      "First open of a new day must show the loading tiles.")
        XCTAssertFalse(app.staticTexts["7h 12m"].exists,
                       "Yesterday's sleep value must never leak into a new day.")
        XCTAssertFalse(app.staticTexts["Green light. Push intensity or volume today."].exists,
                       "Yesterday's recommendation must never leak into a new day.")
        let recoveryCard = app.descendants(matching: .any)["home-recovery-card"].firstMatch
        if recoveryCard.exists {
            XCTAssertFalse(recoveryCard.label.contains("82"),
                           "Yesterday's recovery score must never leak into a new day.")
        }
    }
}
