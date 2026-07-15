import XCTest

/// The archive loop end-to-end: archive a routine from its ⋯ menu, watch it
/// leave the live list and the pinned Archive row appear, restore it from the
/// Archive screen, and watch the row disappear again.
final class RoutineArchiveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testArchiveAndRestoreRoutineRoundTrip() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg", "-initialTab", "workout"]
        app.launch()

        // The seeded starter routine is the archive subject.
        let routineMenu = app.buttons.matching(identifier: "routine-menu-Full Body A").firstMatch
        XCTAssertTrue(routineMenu.waitForExistence(timeout: 8), "Expected the starter routine's menu on the Workout tab.")
        // The 26.5 runtime can report a validly-framed glass control as
        // non-hittable (proxy-node quirk); a coordinate tap sidesteps it.
        if routineMenu.isHittable {
            routineMenu.tap()
        } else {
            routineMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let archiveAction = app.buttons["Archive"]
        XCTAssertTrue(archiveAction.waitForExistence(timeout: 3), "Expected the Archive option in the routine menu.")
        archiveAction.tap()

        // The routine leaves the live list and the pinned entry row appears.
        let archiveRow = element(app, "workout-archive-row")
        XCTAssertTrue(archiveRow.waitForExistence(timeout: 3), "Expected the Archive row once something is archived.")
        XCTAssertFalse(element(app, "start-routine-Full Body A").exists, "Expected the archived routine hidden from the live list.")

        if !archiveRow.isHittable { app.swipeUp() }
        archiveRow.tap()

        let archivedItem = element(app, "archive-item-Full Body A")
        XCTAssertTrue(archivedItem.waitForExistence(timeout: 3), "Expected the routine in the Archive screen.")

        element(app, "archive-restore-Full Body A").tap()
        XCTAssertFalse(element(app, "archive-item-Full Body A").waitForExistence(timeout: 2), "Expected the item gone after restore.")

        app.buttons["Back"].firstMatch.tap()

        XCTAssertTrue(element(app, "start-routine-Full Body A").waitForExistence(timeout: 3), "Expected the restored routine back on the Workout tab.")
        XCTAssertFalse(element(app, "workout-archive-row").exists, "Expected the Archive row gone once the archive is empty.")
    }
}
