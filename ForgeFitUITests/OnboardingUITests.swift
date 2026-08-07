import XCTest

final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testNewUserCanCompleteEssentialSetup() throws {
        let app = launchNewUserApp()

        let getStarted = app.buttons["onboarding-get-started"]
        let importOrRestore = app.buttons["onboarding-import-or-restore"]
        assertPrimaryAction(getStarted, named: "Get started")
        assertPrimaryAction(importOrRestore, named: "Import or restore data")
        XCTAssertTrue(app.staticTexts["Fast workout logging"].exists)
        XCTAssertTrue(app.staticTexts["Built for Apple Watch"].exists)
        XCTAssertTrue(app.staticTexts["Readiness in context"].exists)
        getStarted.tap()

        XCTAssertTrue(app.staticTexts["Set up ForgeFit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Setup"].buttons.firstMatch.isHittable,
                      "Setup should retain a visible native back path.")
        XCTAssertFalse(app.staticTexts["Hybrid Engine"].exists,
                       "Onboarding should not silently choose or advertise a training program.")
        let cardio = app.buttons["onboarding-focus-cardio"]
        XCTAssertTrue(cardio.waitForExistence(timeout: 2))
        cardio.tap()
        XCTAssertEqual(cardio.value as? String, "Selected")

        let kilograms = app.segmentedControls.buttons["kg"]
        XCTAssertTrue(kilograms.exists)
        kilograms.tap()

        let setupContinue = app.buttons["onboarding-setup-continue"]
        assertPrimaryAction(setupContinue, named: "Continue")
        setupContinue.tap()

        XCTAssertTrue(app.staticTexts["Make readiness and Watch metrics work"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Health data is processed on this device"].exists)
        XCTAssertTrue(app.navigationBars["Apple Health"].buttons.firstMatch.isHittable,
                      "The Health explanation should retain a visible native back path.")

        let connect = app.buttons["onboarding-connect-health"]
        let skip = app.buttons["onboarding-continue-without-health"]
        assertPrimaryAction(connect, named: "Connect Apple Health")
        assertPrimaryAction(skip, named: "Continue without Health")
        skip.tap()

        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 8),
                      "Finishing onboarding should reveal the main app.")
    }

    @MainActor
    func testReturningUserCanOpenImporterAndReturn() throws {
        let app = launchNewUserApp()
        app.buttons["onboarding-import-or-restore"].tap()

        XCTAssertTrue(app.navigationBars["Import History"].waitForExistence(timeout: 3))
        app.navigationBars["Import History"].buttons["Close"].tap()

        XCTAssertTrue(app.buttons["onboarding-get-started"].waitForExistence(timeout: 3),
                      "Closing import should return to the welcome screen without losing the setup path.")
    }

    @MainActor
    private func launchNewUserApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-didOnboard", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding-get-started"].waitForExistence(timeout: 10))
        return app
    }

    private func assertPrimaryAction(
        _ element: XCUIElement,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, "Expected \(name).", file: file, line: line)
        XCTAssertTrue(element.isHittable, "\(name) should be visible without scrolling.", file: file, line: line)
        XCTAssertGreaterThanOrEqual(element.frame.height, 44, "\(name) should meet the minimum touch target.", file: file, line: line)
    }

}
