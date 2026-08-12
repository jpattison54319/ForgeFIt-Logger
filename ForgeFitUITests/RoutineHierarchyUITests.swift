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
        XCTAssertTrue(folderHandle("Hybrid Athlete", in: app).exists)
        XCTAssertTrue(card("Single Push", in: app).exists)
        XCTAssertFalse(app.buttons["ungrouped-routines-disclosure"].exists)
    }

    @MainActor
    func testNestedCycleKeepsBothHierarchyLevelsVisible() {
        let app = launch(with: "--seed-routine-hierarchy-nested")

        XCTAssertTrue(folder("Macro 1", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(folder("Hybrid Athlete", in: app).exists)
        XCTAssertTrue(folderHandle("Macro 1", in: app).exists)
        XCTAssertTrue(folderHandle("Hybrid Athlete", in: app).exists)
        XCTAssertTrue(card("Nested Push", in: app).exists)
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
