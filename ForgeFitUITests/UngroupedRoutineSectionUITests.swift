import XCTest

/// Ungrouped is a persistent disclosure, not a synthetic folder. This covers
/// the smallest useful case because a lone routine must still be collapsible.
final class UngroupedRoutineSectionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testOneUngroupedRoutineStaysCollapsedAcrossRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
            "--seed-routine-hierarchy-ungrouped-disclosure",
        ]
        app.launch()

        let disclosure = app.buttons["ungrouped-routines-disclosure"].firstMatch
        let starter = app.buttons["start-routine-Full Body A"].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 8))
        XCTAssertTrue(starter.waitForExistence(timeout: 3))
        keepScreenshot(named: "Ungrouped expanded", from: app)

        tap(disclosure, in: app)
        let collapsed = NSPredicate(format: "value == %@", "Collapsed")
        expectation(for: collapsed, evaluatedWith: disclosure)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(starter.waitForExistence(timeout: 1))
        keepScreenshot(named: "Ungrouped collapsed", from: app)

        app.terminate()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
            "-initialTab", "workout",
            "--seed-routine-hierarchy-ungrouped-disclosure",
        ]
        app.launch()

        let relaunchedDisclosure = app.buttons["ungrouped-routines-disclosure"].firstMatch
        XCTAssertTrue(relaunchedDisclosure.waitForExistence(timeout: 8))
        XCTAssertEqual(relaunchedDisclosure.value as? String, "Collapsed")
        XCTAssertFalse(app.buttons["start-routine-Full Body A"].firstMatch.exists)

        tap(relaunchedDisclosure, in: app)
        XCTAssertTrue(app.buttons["start-routine-Full Body A"].firstMatch.waitForExistence(timeout: 3))
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable {
            app.swipeUp()
        }
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func keepScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
