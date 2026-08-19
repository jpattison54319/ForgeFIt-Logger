import XCTest

final class RoutineReorderingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRoutineLibraryUsesOneOrganizerForFoldersAndRoutines() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
            "--reset-store",
            "--seed-routine-reorder",
        ]
        app.launch()

        let organize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["reorder-routine-Ungrouped One"].exists)
        XCTAssertFalse(app.buttons["reorder-folder-Folder One"].exists)

        organize.tap()
        XCTAssertTrue(app.navigationBars["Organize Routines"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["routine-organizer"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Ungrouped One"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["One A"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Folder One"].firstMatch.exists)
        let moveRoutine = app.buttons["Placement options for routine Ungrouped One"].firstMatch
        XCTAssertTrue(moveRoutine.exists)
        XCTAssertGreaterThanOrEqual(moveRoutine.frame.width, 44)
        XCTAssertGreaterThanOrEqual(moveRoutine.frame.height, 44)
        moveRoutine.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let folderOneDestination = app.buttons["Move to Folder One"].firstMatch
        XCTAssertTrue(folderOneDestination.waitForExistence(timeout: 2))
        folderOneDestination.tap()

        let save = app.buttons["save-routine-organization"].firstMatch
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(app.buttons["organize-routines-button"].firstMatch.waitForExistence(timeout: 3))

        app.buttons["organize-routines-button"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Organize Routines"].firstMatch.waitForExistence(timeout: 3))
        let anotherMove = app.buttons["Placement options for routine Ungrouped Two"].firstMatch
        anotherMove.tap()
        let folderTwoDestination = app.buttons["Move to Folder Two"].firstMatch
        XCTAssertTrue(folderTwoDestination.waitForExistence(timeout: 2))
        folderTwoDestination.tap()
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.sheets["Discard organization changes?"].firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testRoutineDragKeepsNewOrderInsideFolder() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
            "--reset-store",
            "--seed-routine-reorder",
        ]
        app.launch()

        let organize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 8))
        organize.tap()

        let firstHandle = app.buttons["Reorder One A"].firstMatch
        let lastHandle = app.buttons["Reorder One C"].firstMatch
        XCTAssertTrue(firstHandle.waitForExistence(timeout: 3))
        XCTAssertTrue(lastHandle.exists)
        firstHandle.press(forDuration: 0.5, thenDragTo: lastHandle)

        assertRoutine("One A", appearsAfter: "One B", in: app)
        app.buttons["save-routine-organization"].firstMatch.tap()
        XCTAssertTrue(organize.waitForExistence(timeout: 3))
        organize.tap()
        assertRoutine("One A", appearsAfter: "One C", in: app)

        // Reopening the sheet exercises only the live ModelContext. Relaunch
        // without reseeding to prove the order crossed the durable store
        // boundary that failed for users after process termination.
        app.buttons["Cancel"].firstMatch.tap()
        app.terminate()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
        ]
        app.launch()

        let relaunchedOrganize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(relaunchedOrganize.waitForExistence(timeout: 8))
        relaunchedOrganize.tap()
        XCTAssertTrue(app.navigationBars["Organize Routines"].firstMatch.waitForExistence(timeout: 3))
        assertRoutine("One A", appearsAfter: "One C", in: app)
    }

    @MainActor
    private func assertRoutine(
        _ laterName: String,
        appearsAfter earlierName: String,
        in app: XCUIApplication
    ) {
        let cells = app.cells.allElementsBoundByIndex
        let laterIndex = cells.firstIndex { $0.staticTexts[laterName].exists }
        let earlierIndex = cells.firstIndex { $0.staticTexts[earlierName].exists }
        XCTAssertNotNil(laterIndex)
        XCTAssertNotNil(earlierIndex)
        if let laterIndex, let earlierIndex {
            XCTAssertGreaterThan(laterIndex, earlierIndex)
        }
    }

}
