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
    func testDraggingChildAboveParentUnnestsInDroppedOrder() {
        let app = launch(with: "--seed-routine-hierarchy-nested")
        let parent = folder("Macro 1", in: app)
        let child = folder("Hybrid Athlete", in: app)
        let childHandle = folderHandle("Hybrid Athlete", in: app)

        XCTAssertTrue(parent.waitForExistence(timeout: 8))
        XCTAssertTrue(childHandle.exists && childHandle.isHittable)
        XCTAssertGreaterThan(child.frame.minY, parent.frame.minY)

        let source = childHandle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let insertionSlot = app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: parent.frame.midX, dy: parent.frame.minY - 30)
        )
        source.press(
            forDuration: 0.8,
            thenDragTo: insertionSlot,
            withVelocity: .slow,
            thenHoldForDuration: 0.8
        )

        let childMovedAboveParent = NSPredicate { _, _ in
            child.exists && parent.exists && child.frame.minY < parent.frame.minY
        }
        let expectation = XCTNSPredicateExpectation(
            predicate: childMovedAboveParent,
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: 5),
            .completed,
            "Expected the child folder to become a root folder above its former parent."
        )
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
