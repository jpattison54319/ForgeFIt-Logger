import XCTest

/// End-to-end proof that hearts reach the user where they now live: on the
/// workout itself. Drives the real path — finish a workout (which publishes
/// it), then open it from history and read the hearts row. Nothing here
/// stubs the view; if publish, seeding, gating, or rendering breaks, this
/// fails.
final class WorkoutHeartsUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(element.exists, "Never became available: \(element)")
        element.tap()
    }

    @MainActor
    func testHeartsRowAppearsOnOwnWorkoutAfterFriendsHeartIt() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store", "-didOnboard", "YES",
            "--auto-start-routine",
            "--mock-social", "--seed-social-hearts",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        // Finish the auto-started routine so there's a real, share-eligible
        // workout in history. `--seed-social-hearts` plants friends' hearts
        // on eligible workouts at launch, so re-launching is what makes them
        // visible — mirroring production, where hearts arrive between
        // sessions rather than the instant you rack the bar.
        let finish = element(app, "finish-workout-button")
        XCTAssertTrue(finish.waitForExistence(timeout: 15), "Expected the live logger's Finish button.")
        tapWhenReady(finish)
        tapWhenReady(element(app, "save-workout-button"))

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home-workout-"))
                .firstMatch.waitForExistence(timeout: 10),
            "Expected the finished workout in recents."
        )

        // Relaunch WITHOUT --reset-store: the workout persists, and launch
        // seeding hearts it.
        app.terminate()
        app.launchArguments = [
            "-didOnboard", "YES",
            "--mock-social", "--seed-social-hearts",
            "-weightUnitRaw", "kg",
        ]
        app.launch()

        let recentRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "home-workout-"))
            .firstMatch
        XCTAssertTrue(recentRow.waitForExistence(timeout: 15), "Expected the workout to survive relaunch.")
        tapWhenReady(recentRow)

        // The hearts row is async (publish → seed → fetch), so allow for the
        // round trip rather than asserting on the first frame.
        let hearts = element(app, "workout-hearts-row")
        if !hearts.waitForExistence(timeout: 15) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.lifetime = .keepAlways
            shot.name = "hearts-row-missing"
            add(shot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            tree.name = "element-tree"
            add(tree)
            let gate = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "hearts-gate-"))
                .firstMatch
            let gateState = gate.exists ? gate.identifier : "<probe missing>"
            let fetch = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "hearts-fetch-"))
                .firstMatch
            let fetchState = fetch.exists ? fetch.identifier : "<row not mounted>"
            XCTFail("Expected the hearts row. Gate: \(gateState) | Fetch: \(fetchState)")
        }

        // The newest heart leads; the accessibility label carries the count
        // and attribution the visible row shows as "Name +N".
        let label = hearts.label
        XCTAssertTrue(
            label.contains("like"),
            "Expected a like-count summary, got: \(label)"
        )

        // Tapping opens the full liker list.
        tapWhenReady(hearts)
        XCTAssertTrue(
            app.staticTexts["Likes"].waitForExistence(timeout: 5),
            "Expected the likes sheet listing everyone who liked."
        )
    }

}
