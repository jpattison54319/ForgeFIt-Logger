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
    func testUnpairedRoutineHasNoAlternatingLabelOrStartNextAction() {
        let app = launch(with: "--seed-routine-hierarchy-flat")

        let rootPush = card("Root Push", in: app)
        XCTAssertTrue(rootPush.waitForExistence(timeout: 8))
        XCTAssertFalse(rootPush.staticTexts["Alternating with Root Pull"].exists)

        let menu = app.buttons["routine-menu-Root Push"].firstMatch
        tapWhenReady(menu)
        XCTAssertTrue(app.buttons["Add Alternating Routine"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["start-next-Root Push"].firstMatch.exists)
    }

    @MainActor
    func testCrossGroupAlternationStartsTheNextRoutineFromTheMenu() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-cross-group")

        assertCrossGroupPlacement(ungrouped: "Ax400", folderRoutine: "Cindy", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Ax400"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Alternating with Cindy"].firstMatch.exists)

        let cindyMenu = app.buttons["routine-menu-Cindy"].firstMatch
        tapWhenReady(cindyMenu)
        let startNext = app.buttons["start-next-Cindy"].firstMatch
        XCTAssertTrue(startNext.waitForExistence(timeout: 3))
        XCTAssertTrue(startNext.label.contains("Ax400"))
        startNext.acceptanceTap()

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
        assertStartNextAction(routine: "Ax400", expectedNext: "Cindy", in: app)

        completeAndSave("Ax400", expectedExercise: "Machine Chest Press", in: app)

        assertCrossGroupPlacement(ungrouped: "Ax400", folderRoutine: "Cindy", in: app)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Ax400"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alternating with Cindy"].firstMatch.exists)
        assertStartNextAction(routine: "Cindy", expectedNext: "Ax400", in: app)

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
        assertStartNextAction(routine: "Cindy", expectedNext: "Ax400", in: app)
    }

    @MainActor
    func testAlternationOrganizerAddsRemovesReordersAndPersistsMembers() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-multi-member")
        openAlternationOrganizer(for: "Ax400", in: app)

        XCTAssertTrue(app.navigationBars["Alternating Routines"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Ax400"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Cindy"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Fran"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Reorder Ax400"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Remove Cindy from cycle"].firstMatch.exists)

        acceptanceExpect(
            visibleLabels: ["Add Diane to cycle"],
            invariants: ["Add Routine opens a searchable picker without changing the saved cycle."]
        )
        app.buttons["add-alternating-routine"].firstMatch.acceptanceTap()
        let addDiane = app.buttons["Add Diane to cycle"].firstMatch
        XCTAssertTrue(addDiane.waitForExistence(timeout: 3))
        acceptanceExpect(
            ["add-alternating-routine", "save-routine-alternation"],
            visibleLabels: ["Diane"],
            invariants: ["The added routine appears once at the end of the staged cycle."]
        )
        addDiane.acceptanceTap()
        XCTAssertTrue(app.staticTexts["Diane"].firstMatch.waitForExistence(timeout: 3))

        let dianeHandle = app.buttons["Reorder Diane"].firstMatch
        let ax400Handle = app.buttons["Reorder Ax400"].firstMatch
        XCTAssertTrue(dianeHandle.waitForExistence(timeout: 3))
        XCTAssertTrue(ax400Handle.exists)
        acceptanceExpect(
            visibleLabels: ["Diane"],
            invariants: ["Dragging a native reorder handle immediately changes the visible cycle order."]
        )
        dianeHandle.acceptancePress(forDuration: 0.6, thenDragTo: ax400Handle)

        let removeCindy = app.buttons["Remove Cindy from cycle"].firstMatch
        XCTAssertTrue(removeCindy.waitForExistence(timeout: 3))
        acceptanceExpect(
            visibleLabels: ["Diane", "Ax400", "Fran"],
            invariants: ["Removing one member keeps the remaining staged cycle and does not delete the routine."]
        )
        removeCindy.acceptanceTap()
        XCTAssertFalse(app.buttons["Remove Cindy from cycle"].firstMatch.exists)
        acceptanceExpect(
            ["routine-menu-Diane"],
            visibleLabels: ["Diane"],
            invariants: ["Save commits the complete staged membership and order atomically."]
        )
        app.buttons["save-routine-alternation"].firstMatch.acceptanceTap()

        XCTAssertTrue(app.buttons["routine-menu-Diane"].firstMatch.waitForExistence(timeout: 5))
        openAlternationOrganizer(for: "Diane", in: app)
        XCTAssertTrue(app.buttons["Remove Diane from cycle"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove Ax400 from cycle"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Remove Fran from cycle"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Remove Cindy from cycle"].firstMatch.exists)
        XCTAssertLessThan(
            app.buttons["Reorder Diane"].firstMatch.frame.minY,
            app.buttons["Reorder Ax400"].firstMatch.frame.minY
        )
    }

    @MainActor
    func testThreeMemberCrossGroupStartNextUsesTheImmediateSuccessor() {
        let app = launch(with: "--seed-routine-hierarchy-alternating-multi-member")

        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Ax400").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Cindy").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "start-routine-Fran").count, 1)
        XCTAssertTrue(app.staticTexts["Next up · Alternating with Cindy + 1 more"].firstMatch.exists)

        acceptanceExpect(
            ["start-next-Ax400"],
            visibleLabels: ["Start Next, Cindy"],
            invariants: ["A three-member cross-folder cycle renders each routine exactly once and exposes the immediate successor."]
        )
        tapWhenReady(app.buttons["routine-menu-Ax400"].firstMatch)
        let startNext = app.buttons["start-next-Ax400"].firstMatch
        XCTAssertTrue(startNext.waitForExistence(timeout: 3))
        XCTAssertTrue(startNext.label.contains("Cindy"))
        acceptanceExpect(
            ["finish-workout-button"],
            visibleLabels: ["Smith Machine Squat"],
            invariants: ["Start Next launches Cindy, the configured successor of Ax400, rather than an arbitrary other member."]
        )
        startNext.acceptanceTap()
        XCTAssertTrue(app.buttons["finish-workout-button"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Smith Machine Squat"].firstMatch.exists)
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

    private func openAlternationOrganizer(
        for routine: String,
        in app: XCUIApplication
    ) {
        let routineMenu = app.buttons["routine-menu-\(routine)"].firstMatch
        for _ in 0..<3 where !(routineMenu.exists && routineMenu.isHittable) {
            app.acceptanceSwipeUp(velocity: .fast)
        }
        acceptanceExpect(
            visibleLabels: ["Manage Alternating Routines"],
            invariants: ["The routine menu names the multi-member management action explicitly."]
        )
        tapWhenReady(routineMenu)
        let manage = app.buttons["Manage Alternating Routines"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 3))
        acceptanceExpect(
            ["add-alternating-routine", "save-routine-alternation"],
            visibleLabels: ["Order", "Stop Alternating"],
            invariants: ["The organizer exposes add, remove, numbered order, native reorder handles, Cancel, and Save without hidden gestures."]
        )
        manage.acceptanceTap()
    }

    private func assertStartNextAction(
        routine: String,
        expectedNext: String,
        in app: XCUIApplication
    ) {
        tapWhenReady(app.buttons["routine-menu-\(routine)"].firstMatch)
        let startNext = app.buttons["start-next-\(routine)"].firstMatch
        XCTAssertTrue(startNext.waitForExistence(timeout: 3))
        XCTAssertTrue(startNext.label.contains(expectedNext))
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
