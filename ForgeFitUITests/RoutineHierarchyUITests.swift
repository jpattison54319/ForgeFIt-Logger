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
        organize.acceptanceTap()
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
        organize.acceptanceTap()

        let moveChild = app.buttons["Placement options for folder Hybrid Athlete"].firstMatch
        XCTAssertTrue(moveChild.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(moveChild.frame.width, 44)
        XCTAssertGreaterThanOrEqual(moveChild.frame.height, 44)
        moveChild.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).acceptanceTap()
        let topLevel = app.buttons["Top Level"].firstMatch
        XCTAssertTrue(topLevel.waitForExistence(timeout: 2))
        topLevel.acceptanceTap()
        app.buttons["save-routine-organization"].firstMatch.acceptanceTap()

        XCTAssertTrue(organize.waitForExistence(timeout: 3))
        organize.acceptanceTap()
        XCTAssertTrue(moveChild.waitForExistence(timeout: 3))
        moveChild.acceptanceTap()
        XCTAssertFalse(app.buttons["Top Level"].firstMatch.waitForExistence(timeout: 1))
    }

    @MainActor
    func testOrganizerDragCanMoveSubfolderBackToTopLevel() {
        let app = launch(with: "--seed-routine-hierarchy-nested")
        let organize = app.buttons["organize-routines-button"].firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 8))
        organize.acceptanceTap()

        let childHandle = app.buttons["Reorder Hybrid Athlete"].firstMatch
        let parentHandle = app.buttons["Reorder Macro 1"].firstMatch
        XCTAssertTrue(childHandle.waitForExistence(timeout: 3))
        XCTAssertTrue(parentHandle.exists)
        childHandle.acceptancePress(forDuration: 0.5, thenDragTo: parentHandle)

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
    func testUnpairedRoutineHasNoAlternatingLabelOrOtherStartAction() {
        let app = launch(with: "--seed-routine-hierarchy-flat")

        let rootPush = card("Root Push", in: app)
        XCTAssertTrue(rootPush.waitForExistence(timeout: 8))
        XCTAssertFalse(rootPush.staticTexts["Alternating with Root Pull"].exists)

        let menu = app.buttons["routine-menu-Root Push"].firstMatch
        tapWhenReady(menu)
        XCTAssertTrue(app.buttons["Add Alternating Routine"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Start Root Pull Instead"].firstMatch.exists)
    }

    @MainActor
    func testCrossGroupAlternationStartsTheOtherRoutineFromTheMenu() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-cross-group")

        assertCrossGroupPlacement(ungrouped: "Ax400", folderRoutine: "Cindy", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Ax400"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Alternating with Cindy"].firstMatch.exists)

        let cindyMenu = app.buttons["routine-menu-Cindy"].firstMatch
        tapWhenReady(cindyMenu)
        let startAx400Instead = app.buttons["Start Ax400 Instead"].firstMatch
        XCTAssertTrue(startAx400Instead.waitForExistence(timeout: 3))
        startAx400Instead.acceptanceTap()

        let finish = app.buttons["finish-workout-button"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Machine Chest Press"].firstMatch.waitForExistence(timeout: 5))

        completeCurrentWorkoutAndSave(in: app)
        assertCrossGroupPlacement(ungrouped: "Ax400", folderRoutine: "Cindy", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Ax400"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func testCompletedAlternatingRoutinesSwapCrossGroupCardsInBothDirections() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-cross-group-owner-due")

        assertCrossGroupPlacement(ungrouped: "Cindy", folderRoutine: "Ax400", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Cindy"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Alternating with Ax400"].firstMatch.exists)
        assertOtherStartAction(routine: "Ax400", other: "Cindy", in: app)

        completeAndSave("Ax400", expectedExercise: "Machine Chest Press", in: app)

        assertCrossGroupPlacement(ungrouped: "Ax400", folderRoutine: "Cindy", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Ax400"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alternating with Cindy"].firstMatch.exists)
        assertOtherStartAction(routine: "Cindy", other: "Ax400", in: app)

        completeAndSave("Cindy", expectedExercise: "Smith Machine Squat", in: app)

        assertCrossGroupPlacement(ungrouped: "Cindy", folderRoutine: "Ax400", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Cindy"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alternating with Ax400"].firstMatch.exists)
    }

    @MainActor
    func testSameFolderAlternationSwapsNamesWithoutMovingEitherSlot() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-same-group")

        let samePlan = folder("Same Plan", in: app)
        let cindy = card("Cindy", in: app)
        let ax400 = card("Ax400", in: app)
        XCTAssertTrue(samePlan.waitForExistence(timeout: 8))
        XCTAssertTrue(cindy.exists)
        XCTAssertTrue(ax400.exists)
        XCTAssertFalse(app.buttons["ungrouped-routines-disclosure"].exists)
        XCTAssertLessThan(samePlan.frame.minY, cindy.frame.minY)
        XCTAssertLessThan(cindy.frame.minY, ax400.frame.minY)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Cindy").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Ax400").count, 1)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Ax400"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Alternating with Cindy"].firstMatch.exists)
        assertOtherStartAction(routine: "Cindy", other: "Ax400", in: app)
    }

    private func assertCrossGroupPlacement(
        ungrouped: String,
        folderRoutine: String,
        in app: XCUIApplication
    ) {
        let ungroupedCard = card(ungrouped, in: app)
        let groupedCard = card(folderRoutine, in: app)
        let axPlans = folder("AX Plans", in: app)
        XCTAssertTrue(ungroupedCard.waitForExistence(timeout: 8))
        XCTAssertTrue(groupedCard.waitForExistence(timeout: 3))
        XCTAssertTrue(axPlans.exists)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Ax400").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Cindy").count, 1)
        XCTAssertLessThan(ungroupedCard.frame.minY, axPlans.frame.minY)
        XCTAssertGreaterThan(groupedCard.frame.minY, axPlans.frame.minY)
    }

    private func assertOtherStartAction(
        routine: String,
        other: String,
        in app: XCUIApplication
    ) {
        tapWhenReady(app.buttons["routine-menu-\(routine)"].firstMatch)
        XCTAssertTrue(app.buttons["Start \(other) Instead"].firstMatch.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).acceptanceTap()
    }

    private func completeAndSave(
        _ routine: String,
        expectedExercise: String,
        in app: XCUIApplication
    ) {
        tapWhenReady(app.buttons["start-routine-\(routine)"].firstMatch)
        XCTAssertTrue(app.buttons["finish-workout-button"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts[expectedExercise].firstMatch.waitForExistence(timeout: 5))
        completeCurrentWorkoutAndSave(in: app)
    }

    private func completeCurrentWorkoutAndSave(in app: XCUIApplication) {
        tapWhenReady(app.buttons["complete-set-1"].firstMatch)
        tapWhenReady(app.buttons["finish-workout-button"].firstMatch)
        let save = app.buttons["save-workout-button"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 8))
        tapWhenReady(save)
        XCTAssertFalse(app.buttons["finish-workout-button"].firstMatch.waitForExistence(timeout: 3))
    }

    private func tapWhenReady(_ element: XCUIElement, timeout: TimeInterval = 8) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard element.exists, element.isHittable else {
            XCTFail("Element never became hittable: \(element)")
            return
        }
        element.acceptanceTap()
    }

    @MainActor
    private func launch(with fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "-workoutUngroupedCollapsed", "NO",
            "--reset-store",
            fixture,
        ]
        app.acceptanceLaunch()
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
