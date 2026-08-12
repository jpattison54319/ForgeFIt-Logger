import XCTest

final class RoutineExerciseDisclosureUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testLongRoutineDefaultsClosedExpandsAndResetsAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-didOnboard", "YES",
            "-initialTab", "workout",
            "--reset-store",
            "--seed-routine-hierarchy-many-exercises",
        ]
        app.launch()

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

        app.terminate()
        app.launch()

        let relaunchedDisclosure = app.buttons["routine-exercise-disclosure-Long Routine"].firstMatch
        XCTAssertTrue(relaunchedDisclosure.waitForExistence(timeout: 8))
        XCTAssertEqual(relaunchedDisclosure.value as? String, "Collapsed")
        XCTAssertFalse(summaryItem("Bayesian Cable Curl", routine: "Long Routine", in: app).exists)
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
