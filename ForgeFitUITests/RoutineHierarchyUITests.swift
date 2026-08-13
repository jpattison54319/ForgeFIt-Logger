import XCTest

final class RoutineHierarchyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testFlatLibraryShowsRoutinesWithoutSyntheticUngroupedHeader() {
        let app = launch(with: "--seed-routine-hierarchy-flat")

        XCTAssertTrue(card("Root Push", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(card("Root Pull", in: app).exists)
        XCTAssertFalse(app.buttons["ungrouped-routines-disclosure"].exists)
    }

    @MainActor
    func testSingleFolderUsesFolderDisclosureWithoutUngroupedHeader() {
        let app = launch(with: "--seed-routine-hierarchy-single")

        XCTAssertTrue(folder("Hybrid Athlete", in: app).waitForExistence(timeout: 8))
        XCTAssertFalse(folderHandle("Hybrid Athlete", in: app).exists)
        XCTAssertTrue(card("Single Push", in: app).exists)
        XCTAssertFalse(app.buttons["ungrouped-routines-disclosure"].exists)
    }

    @MainActor
    func testNestedCycleKeepsBothHierarchyLevelsVisible() {
        let app = launch(with: "--seed-routine-hierarchy-nested")

        XCTAssertTrue(folder("Macro 1", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(folder("Hybrid Athlete", in: app).exists)
        XCTAssertFalse(folderHandle("Macro 1", in: app).exists)
        XCTAssertFalse(folderHandle("Hybrid Athlete", in: app).exists)
        XCTAssertTrue(card("Nested Push", in: app).exists)
    }

    @MainActor
    func testNestedCycleOpensInUnifiedOrganizer() {
        let app = launch(with: "--seed-routine-hierarchy-nested")
        let organize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 8))
        organize.tap()
        XCTAssertTrue(app.navigationBars["Organize Routines"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Macro 1"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Hybrid Athlete"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Nested Push"].firstMatch.exists)
    }

    @MainActor
    func testOrganizerCanMoveSubfolderBackToTopLevel() {
        let app = launch(with: "--seed-routine-hierarchy-nested")
        let organize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 8))
        organize.tap()

        let moveChild = app.buttons["Placement options for folder Hybrid Athlete"].firstMatch
        XCTAssertTrue(moveChild.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(moveChild.frame.width, 44)
        XCTAssertGreaterThanOrEqual(moveChild.frame.height, 44)
        moveChild.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        let topLevel = app.buttons["Top Level"].firstMatch
        XCTAssertTrue(topLevel.waitForExistence(timeout: 2))
        topLevel.tap()
        app.buttons["save-routine-organization"].firstMatch.tap()

        XCTAssertTrue(organize.waitForExistence(timeout: 3))
        organize.tap()
        XCTAssertTrue(moveChild.waitForExistence(timeout: 3))
        moveChild.tap()
        XCTAssertFalse(app.buttons["Top Level"].firstMatch.waitForExistence(timeout: 1))
    }

    @MainActor
    func testOrganizerDragCanMoveSubfolderBackToTopLevel() {
        let app = launch(with: "--seed-routine-hierarchy-nested")
        let organize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 8))
        organize.tap()

        let childHandle = app.buttons["Reorder Hybrid Athlete"].firstMatch
        let parentHandle = app.buttons["Reorder Macro 1"].firstMatch
        XCTAssertTrue(childHandle.waitForExistence(timeout: 3))
        XCTAssertTrue(parentHandle.exists)
        childHandle.press(forDuration: 0.5, thenDragTo: parentHandle)

        let cells = app.cells.allElementsBoundByIndex
        let childIndex = cells.firstIndex { $0.staticTexts["Hybrid Athlete"].exists }
        let parentIndex = cells.firstIndex { $0.staticTexts["Macro 1"].exists }
        XCTAssertNotNil(childIndex)
        XCTAssertNotNil(parentIndex)
        if let childIndex, let parentIndex {
            XCTAssertLessThan(childIndex, parentIndex)
        }
    }

    @MainActor
    func testMixedLibraryLabelsRootRoutinesAsUngrouped() {
        let app = launch(with: "--seed-routine-hierarchy-mixed")

        XCTAssertTrue(card("Root Hotel", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["ungrouped-routines-disclosure"].exists)
        XCTAssertTrue(folder("Hybrid Athlete", in: app).exists)
        XCTAssertTrue(card("Mixed Push", in: app).exists)
    }

    @MainActor
    func testCrossGroupAlternationKeepsEachRoutineInItsOwnAccessibleCard() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-cross-group")

        let ax400 = card("Ax400", in: app)
        let cindy = card("Cindy", in: app)
        XCTAssertTrue(ax400.waitForExistence(timeout: 8))
        XCTAssertTrue(cindy.exists)
        XCTAssertTrue(app.buttons["start-routine-Ax400"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Cindy").count, 1)

        let ax400Title = ax400.staticTexts["Ax400"].firstMatch
        XCTAssertTrue(ax400Title.exists)
        ax400Title.tap()

        XCTAssertTrue(app.buttons["Edit Routine"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ax400"].firstMatch.exists)
    }

    @MainActor
    private func launch(with fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
            "--reset-store",
            fixture,
        ]
        app.launch()
        return app
    }

    private func card(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["routine-card-\(name)"].firstMatch
    }

    private func folder(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["routine-folder-\(name)"].firstMatch
    }

    private func folderHandle(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["reorder-folder-\(name)"].firstMatch
    }
}
