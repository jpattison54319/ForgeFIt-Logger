import XCTest

final class RoutineExerciseDisclosureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testLongRoutineDefaultsClosedExpandsAndResetsAfterRelaunch() {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "--reset-store",
            "--seed-routine-hierarchy-many-exercises",
        ]
        app.acceptanceLaunch()

        let disclosure = app.buttons["routine-exercise-disclosure-Long Routine"].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 8))
        XCTAssertEqual(disclosure.value as? String, "Collapsed")
        XCTAssertTrue(summaryItem("Machine Chest Press", routine: "Long Routine", in: app).exists)
        XCTAssertTrue(summaryItem("Overhead Cable Triceps Extension", routine: "Long Routine", in: app).exists)
        XCTAssertTrue(summaryItem("Chest-Supported T-Bar Row", routine: "Long Routine", in: app).exists)
        XCTAssertFalse(summaryItem("Bayesian Cable Curl", routine: "Long Routine", in: app).exists)
        XCTAssertTrue(app.descendants(matching: .any)["routine-card-Short Routine"].firstMatch.exists)
        XCTAssertTrue(summaryItem("Romanian Deadlift", routine: "Short Routine", in: app).exists)
        XCTAssertTrue(summaryItem("Smith Machine Squat", routine: "Short Routine", in: app).exists)
        XCTAssertFalse(app.buttons["routine-exercise-disclosure-Short Routine"].exists)
        keepScreenshot(named: "Routine exercises collapsed", from: app)

        tap(disclosure, in: app)

        XCTAssertTrue(
            summaryItem("Bayesian Cable Curl", routine: "Long Routine", in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(disclosure.value as? String, "Expanded")
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.3))
        keepScreenshot(named: "Routine exercises expanded", from: app)

        app.acceptanceTerminate()
        app.acceptanceLaunch()

        let relaunchedDisclosure = app.buttons["routine-exercise-disclosure-Long Routine"].firstMatch
        XCTAssertTrue(relaunchedDisclosure.waitForExistence(timeout: 8))
        XCTAssertEqual(relaunchedDisclosure.value as? String, "Collapsed")
        XCTAssertFalse(summaryItem("Bayesian Cable Curl", routine: "Long Routine", in: app).exists)
    }

    @MainActor
    func testRoutineEditorActionsRemainAvailableAfterScrolling() {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "--reset-store",
            "--seed-routine-hierarchy-many-exercises",
        ]
        app.acceptanceLaunch()

        let menu = app.buttons["routine-menu-Long Routine"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        tap(menu, in: app)

        let edit = app.buttons["Edit Long Routine"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.acceptanceTap()

        let back = app.buttons["routine-editor-back-button"].firstMatch
        let save = app.buttons["routine-editor-save-button"].firstMatch
        let scroll = app.scrollViews["routine-editor-scroll"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(scroll.exists)
        XCTAssertTrue(back.isHittable)
        XCTAssertTrue(save.isHittable)
        XCTAssertGreaterThanOrEqual(back.frame.width, 44)
        XCTAssertGreaterThanOrEqual(back.frame.height, 44)
        XCTAssertGreaterThanOrEqual(save.frame.width, 44)
        XCTAssertGreaterThanOrEqual(save.frame.height, 44)
        let originalBackY = back.frame.midY
        let originalSaveY = save.frame.midY

        scroll.acceptanceSwipeUp()
        scroll.acceptanceSwipeUp()
        XCTAssertTrue(app.buttons["add-to-routine"].firstMatch.waitForExistence(timeout: 3))

        XCTAssertTrue(back.isHittable, "Back must remain available throughout the routine.")
        XCTAssertTrue(save.isHittable, "Save must remain available throughout the routine.")
        XCTAssertEqual(back.frame.midY, originalBackY, accuracy: 2)
        XCTAssertEqual(save.frame.midY, originalSaveY, accuracy: 2)
        keepScreenshot(named: "Routine editor persistent glass actions", from: app)
    }

    private func summaryItem(
        _ itemName: String,
        routine routineName: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.staticTexts["routine-summary-item-\(routineName)-\(itemName)"].firstMatch
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable {
            app.acceptanceSwipeUp()
        }
        if element.isHittable {
            element.acceptanceTap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).acceptanceTap()
        }
    }

    private func keepScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
