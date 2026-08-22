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
        XCTAssertTrue(app.staticTexts["Recovery with context"].exists)
        XCTAssertTrue(app.staticTexts["You can import a workout CSV anytime from Settings."].exists)
        getStarted.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Set up ForgeFit"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Setup"].buttons.firstMatch.isHittable,
                      "Setup should retain a visible native back path.")
        XCTAssertFalse(app.staticTexts["Hybrid Engine"].exists,
                       "Onboarding should not silently choose or advertise a training program.")
        let cardio = app.buttons["onboarding-focus-cardio"]
        XCTAssertTrue(cardio.waitForExistence(timeout: 2))
        cardio.acceptanceTap()
        XCTAssertEqual(cardio.value as? String, "Selected")

        let kilograms = app.segmentedControls.buttons["kg"]
        XCTAssertTrue(kilograms.exists)
        kilograms.acceptanceTap()

        let setupContinue = app.buttons["onboarding-setup-continue"]
        assertPrimaryAction(setupContinue, named: "Continue")
        setupContinue.acceptanceTap()

        XCTAssertTrue(app.staticTexts["Connect Apple Health"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Your Health data stays on this device"].exists)
        XCTAssertTrue(app.navigationBars["Apple Health"].buttons.firstMatch.isHittable,
                      "The Health explanation should retain a visible native back path.")

        // Guideline 5.1.1(iv): the explainer must lead to Apple's permission
        // sheet, so Continue is the only control and there is no way to skip
        // past the request.
        let healthContinue = app.buttons["onboarding-continue-health"]
        assertPrimaryAction(healthContinue, named: "Continue to Apple Health")
        XCTAssertFalse(app.buttons["onboarding-continue-without-health"].exists,
                       "The Health step must not offer a way around the permission request.")
        XCTAssertFalse(app.buttons["onboarding-open-health-settings"].exists,
                       "The Health step must present exactly one forward action.")
        healthContinue.acceptanceTap()

        XCTAssertTrue(app.buttons["tab-home"].waitForExistence(timeout: 8),
                      "Finishing onboarding should reveal the main app.")
    }

    @MainActor
    func testReturningUserCanOpenImporterAndReturn() throws {
        let app = launchNewUserApp()
        app.buttons["onboarding-import-or-restore"].acceptanceTap()

        XCTAssertTrue(app.navigationBars["Import History"].waitForExistence(timeout: 3))
        app.navigationBars["Import History"].buttons["Close"].acceptanceTap()

        XCTAssertTrue(app.buttons["onboarding-get-started"].waitForExistence(timeout: 3),
                      "Closing import should return to the welcome screen without losing the setup path.")
    }

    @MainActor
    func testCapturePolishedOnboarding() throws {
        let app = launchNewUserApp()
        capture(app, name: "01-welcome")

        app.buttons["onboarding-import-or-restore"].acceptanceTap()
        XCTAssertTrue(app.navigationBars["Import History"].waitForExistence(timeout: 3))
        capture(app, name: "02-import-or-restore")
        app.navigationBars["Import History"].buttons["Close"].acceptanceTap()

        app.buttons["onboarding-get-started"].acceptanceTap()
        XCTAssertTrue(app.staticTexts["Set up ForgeFit"].waitForExistence(timeout: 3))
        capture(app, name: "03-setup")

        app.buttons["onboarding-setup-continue"].acceptanceTap()
        XCTAssertTrue(app.staticTexts["Connect Apple Health"].waitForExistence(timeout: 3))
        capture(app, name: "04-apple-health")
    }

    @MainActor
    private func launchNewUserApp() -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        // Onboarding's Continue always requests HealthKit authorization now, and
        // the real system sheet cannot be driven from a test, so stub it out.
        app.launchArguments = [
            "--stub-health-authorization",
            "-didOnboard", "NO",
            "-weightUnitRaw", "lb",
            "-trainingFocusRaw", "mixed"
        ]
        app.acceptanceLaunch()
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

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
