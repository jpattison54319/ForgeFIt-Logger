import XCTest

final class QuickIncrementSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testCustomSettingsPersistAndEveryRepAndWeightBandUsesItsAmount() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = settingsArguments
        app.acceptanceLaunch()
        openSettings(app)

        let custom = [("reps", ["2", "6", "11"]), ("pounds", ["0.25", "1.75", "12.25"]), ("kilograms", ["0.1", "0.75", "4.5"])]
        for (group, amounts) in custom {
            for (index, amount) in amounts.enumerated() {
                let field = app.textFields["quick-increment-\(group)-\(index)"]
                reveal(field, app: app)
                replaceText(field, with: amount)
                XCTAssertEqual(field.value as? String, amount)
                app.buttons["quick-increment-keyboard-done"].acceptanceTap()
            }
        }
        acceptanceExpect(invariants: ["Save commits all nine independent increment amounts"])
        app.buttons["quick-increment-save"].acceptanceTap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.acceptanceTerminate()
        app.launchArguments.removeAll { $0 == "--reset-store" }
        app.acceptanceLaunch()
        openSettings(app)
        for (group, amounts) in custom {
            for (index, amount) in amounts.enumerated() {
                let field = app.textFields["quick-increment-\(group)-\(index)"]
                reveal(field, app: app)
                XCTAssertEqual(field.value as? String, amount)
            }
        }
        app.acceptanceTerminate()
        app.launchArguments = ["--seed-quick-increment-history", "--skip-onboarding", "--auto-start-routine", "--suppress-health-refresh", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        app.acceptanceLaunch()
        let weight = app.textFields.matching(NSPredicate(format: "label == %@", "Weight")).firstMatch
        if !weight.waitForExistence(timeout: 15) {
            let resume = app.buttons["Resume workout"].firstMatch
            if resume.exists { resume.acceptanceTap() }
        }
        XCTAssertTrue(weight.waitForExistence(timeout: 10))
        let switchUnit = app.buttons["Switch Machine Chest Press weight unit"].firstMatch
        XCTAssertTrue(switchUnit.waitForExistence(timeout: 5))
        if app.staticTexts["LBS"].firstMatch.exists { switchUnit.acceptanceTap() }
        XCTAssertTrue(app.staticTexts["KG"].firstMatch.waitForExistence(timeout: 3))

        // Explicit values isolate arithmetic from unrelated suggestion policy.
        replaceText(weight, with: "100")
        app.buttons["Dismiss keyboard"].firstMatch.acceptanceTap()
        try checkBands(weight, expected: [104.5, 105.25, 105.35, 105.25, 104.5, 100], app: app)

        switchUnit.acceptanceTap()
        XCTAssertTrue(app.staticTexts["LBS"].firstMatch.waitForExistence(timeout: 3))
        replaceText(weight, with: "100")
        app.buttons["Dismiss keyboard"].firstMatch.acceptanceTap()
        try checkBands(weight, expected: [112.25, 114, 114.25, 114, 112.25, 100], app: app)

        let reps = app.textFields.matching(NSPredicate(format: "label == %@", "Reps")).firstMatch
        XCTAssertTrue(reps.exists)
        replaceText(reps, with: "10")
        app.buttons["Dismiss keyboard"].firstMatch.acceptanceTap()
        try checkBands(reps, expected: [21, 27, 29, 27, 21, 10], app: app)
        chooseBand(reps, offset: 138)
        XCTAssertEqual(reps.value as? String, "0")
    }

    @MainActor
    func testSettingsValidationAndResetAtAccessibilityTextSize() {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = settingsArguments + ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.acceptanceLaunch()
        openSettings(app)
        let field = app.textFields["quick-increment-reps-0"]
        reveal(field, app: app)
        replaceText(field, with: "0")
        XCTAssertFalse(app.buttons["quick-increment-save"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any)["quick-increment-reps-error"].exists)
        app.buttons["quick-increment-keyboard-done"].acceptanceTap()
        let reset = app.buttons["quick-increment-reset"]
        reveal(reset, app: app)
        XCTAssertGreaterThanOrEqual(reset.frame.height, 44)
        acceptanceExpect(invariants: ["Reset restores the shipped three amounts for reps, pounds, and kilograms"])
        reset.acceptanceTap()
        app.buttons["quick-increment-save"].acceptanceTap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.acceptanceTerminate()
        app.launchArguments.removeAll { $0 == "--reset-store" }
        app.acceptanceLaunch()
        openSettings(app)
        for (group, values) in [("reps", ["1", "2", "3"]), ("pounds", ["2.5", "5", "7.5"]), ("kilograms", ["1.25", "2.5", "3.75"])] {
            for (index, value) in values.enumerated() {
                let entry = app.textFields["quick-increment-\(group)-\(index)"]
                reveal(entry, app: app)
                XCTAssertEqual(entry.value as? String, value)
                XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
            }
        }
    }

    private var settingsArguments: [String] {
        ["--reset-store", "--skip-onboarding", "--suppress-health-refresh", "-didOnboard", "YES", "-initialTab", "profile"]
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.acceptanceTap()
        let entry = app.buttons["settings-quick-increments"].firstMatch
        reveal(entry, app: app)
        entry.acceptanceTap()
        XCTAssertTrue(app.navigationBars["Quick increments"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            if element.exists && element.frame.minY < app.frame.midY {
                app.acceptanceSwipeDown(velocity: .slow)
            } else {
                app.acceptanceSwipeUp(velocity: .slow)
            }
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func replaceText(_ field: XCUIElement, with text: String) {
        // Right-aligned numeric fields need the caret at the end before
        // backspacing; a center tap can place it before the first digit.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).acceptanceTap()
        let count = (field.value as? String ?? "").count
        field.acceptanceTypeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + text)
    }

    @MainActor
    private func chooseBand(_ field: XCUIElement, offset: CGFloat) {
        let start = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.acceptancePress(forDuration: 0.55, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)), withVelocity: .fast, thenHoldForDuration: 0)
    }

    @MainActor
    private func checkBands(_ field: XCUIElement, expected: [Double], app: XCUIApplication) throws {
        for (index, offset) in [-138.0, -94, -50, 50, 94, 138].enumerated() {
            acceptanceExpect(invariants: ["Custom band \(index) produces \(expected[index]) exactly once"])
            chooseBand(field, offset: offset)
            let value = try XCTUnwrap(Double((field.value as? String ?? "").replacingOccurrences(of: ",", with: ".")))
            XCTAssertEqual(value, expected[index], accuracy: 0.001)
            XCTAssertFalse(app.descendants(matching: .any)["quick-increment-option-0"].exists)
        }
    }
}
