import XCTest

final class RoutineReorderingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRoutineLibraryShowsDedicatedReorderHandlesAndEditOrderFallback() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
            "--reset-store",
            "--seed-routine-reorder",
        ]
        app.launch()

        let ungroupedHandle = handle("Ungrouped One", in: app)
        XCTAssertTrue(ungroupedHandle.waitForExistence(timeout: 8))
        XCTAssertTrue(ungroupedHandle.isHittable)

        let folderRoutineHandle = handle("One A", in: app)
        scrollUntilHittable(folderRoutineHandle, in: app)
        XCTAssertTrue(
            folderRoutineHandle.exists && folderRoutineHandle.isHittable,
            "Expected a visible hold-to-reorder handle on a routine inside a folder."
        )

        // The UIKit continuous hold is intentionally verified on physical
        // hardware: XCUITest cannot reliably synthesize the handle gesture
        // inside this vertical scroll (the same limitation as exercise rows).
        let editOrder = app.buttons["edit-routine-order-button"].firstMatch
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(editOrder.waitForExistence(timeout: 3))
        editOrder.tap()
        XCTAssertTrue(app.navigationBars["Edit Order"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ungrouped One"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["One A"].firstMatch.exists)
    }

    private func handle(_ routineName: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["reorder-routine-\(routineName)"].firstMatch
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            app.swipeUp(velocity: .slow)
        }
    }
}
