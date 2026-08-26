import XCTest

/// Custom exercise muscle selection stays anatomically specific and cannot
/// assign the same region as both primary and secondary.
final class ExerciseMusclePickerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func button(_ app: XCUIApplication, label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func menuOracle(
        _ app: XCUIApplication,
        id: String,
        requiredLabels: [String],
        forbiddenLabels: [String]
    ) -> AcceptanceOracle {
        AcceptanceOracle(id: id) {
            let missing = requiredLabels.filter { !self.button(app, label: $0).exists }
            let present = forbiddenLabels.filter { self.button(app, label: $0).exists }
            let passed = missing.isEmpty && present.isEmpty
            return AcceptanceOracleResult(
                id: id,
                outcome: passed ? .pass : .fail,
                message: passed
                    ? "The menu showed the required choices and omitted invalid muscle choices."
                    : "Missing: \(missing.joined(separator: ", ")); unexpectedly present: \(present.joined(separator: ", "))."
            )
        }
    }

    private func pickerValueOracle(
        _ picker: XCUIElement,
        id: String,
        expectedValue: String
    ) -> AcceptanceOracle {
        AcceptanceOracle(id: id) {
            let actual = picker.value as? String
            let passed = actual == expectedValue
            return AcceptanceOracleResult(
                id: id,
                outcome: passed ? .pass : .fail,
                message: passed
                    ? "The picker value is \(expectedValue)."
                    : "Expected \(expectedValue), found \(actual ?? "no accessibility value")."
            )
        }
    }

    @MainActor
    func testHipsGroupsSpecificMusclesAndPrimaryCannotRepeatAsSecondary() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding",
            "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]

        acceptanceExpect(
            ["start-empty-workout"],
            phase: .setup,
            invariants: ["A clean launch reaches the empty-workout action."]
        )
        app.acceptanceLaunch()

        let startEmptyWorkout = element(app, "start-empty-workout")
        try acceptanceRequire(
            startEmptyWorkout.waitForExistence(timeout: 15),
            "Expected the empty-workout action after deterministic launch."
        )
        acceptanceExpect(
            ["add-to-workout"],
            phase: .setup,
            invariants: ["Starting an empty workout opens the live logger."]
        )
        startEmptyWorkout.acceptanceTap()

        let replaceActiveWorkout = button(app, label: "Discard Current & Start New")
        if replaceActiveWorkout.waitForExistence(timeout: 2) {
            acceptanceExpect(
                ["add-to-workout"],
                phase: .setup,
                invariants: ["The supported replacement action opens a fresh live logger."]
            )
            replaceActiveWorkout.acceptanceTap()
        }

        let addExercise = element(app, "add-to-workout")
        try acceptanceRequire(
            addExercise.waitForExistence(timeout: 10),
            "Expected the add-exercise action in the live logger."
        )
        acceptanceExpect(
            ["create-exercise-button"],
            phase: .setup,
            invariants: ["Adding to the workout opens the exercise picker."]
        )
        addExercise.acceptanceTap()

        let createExercise = element(app, "create-exercise-button")
        try acceptanceRequire(
            createExercise.waitForExistence(timeout: 8),
            "Expected the visible create-exercise action."
        )
        acceptanceExpect(
            ["primary-muscle-picker", "secondary-muscle-picker"],
            invariants: ["The custom exercise form exposes both muscle pickers."]
        )
        createExercise.acceptanceTap()

        let primary = element(app, "primary-muscle-picker")
        let secondary = element(app, "secondary-muscle-picker")
        try acceptanceRequire(
            primary.waitForExistence(timeout: 8) && secondary.exists,
            "Expected both muscle pickers on the custom exercise form."
        )

        acceptanceExpect(
            visibleLabels: ["Hips"],
            invariants: ["Hips is a navigation group; Spine is not a selectable muscle."],
            oracles: [menuOracle(
                app,
                id: "hips-group-replaces-hip-and-spine-options",
                requiredLabels: ["Hips"],
                forbiddenLabels: ["Spine", "Cardiovascular"]
            )]
        )
        primary.acceptanceTap()

        let hips = button(app, label: "Hips")
        XCTAssertTrue(hips.waitForExistence(timeout: 5), "Expected the Hips navigation group.")
        acceptanceExpect(
            visibleLabels: ["Abductors", "Adductors", "Glutes", "Hip Flexors"],
            invariants: ["Hips expands to specific muscles and cannot itself be selected."],
            oracles: [menuOracle(
                app,
                id: "hips-opens-specific-muscles-only",
                requiredLabels: ["Abductors", "Adductors", "Glutes", "Hip Flexors"],
                forbiddenLabels: ["All Hips"]
            )]
        )
        hips.acceptanceTap()

        let hipFlexors = button(app, label: "Hip Flexors")
        XCTAssertTrue(hipFlexors.waitForExistence(timeout: 5), "Expected Hip Flexors inside Hips.")
        acceptanceExpect(
            ["primary-muscle-picker", "secondary-muscle-picker"],
            invariants: ["Choosing Hip Flexors records the specific primary muscle."],
            oracles: [pickerValueOracle(
                primary,
                id: "hip-flexors-is-the-primary-muscle",
                expectedValue: "Hip Flexors"
            )]
        )
        hipFlexors.acceptanceTap()

        acceptanceExpect(
            visibleLabels: ["Hips"],
            invariants: ["The secondary picker retains the same anatomical grouping."],
            oracles: [menuOracle(
                app,
                id: "secondary-picker-has-hips-group",
                requiredLabels: ["Hips"],
                forbiddenLabels: ["Spine", "Cardiovascular"]
            )]
        )
        secondary.acceptanceTap()

        let secondaryHips = button(app, label: "Hips")
        XCTAssertTrue(secondaryHips.waitForExistence(timeout: 5), "Expected Hips in the secondary picker.")
        acceptanceExpect(
            visibleLabels: ["Abductors", "Adductors", "Glutes"],
            invariants: ["The primary Hip Flexors choice is unavailable as a secondary muscle."],
            oracles: [menuOracle(
                app,
                id: "primary-muscle-is-excluded-from-secondaries",
                requiredLabels: ["Abductors", "Adductors", "Glutes"],
                forbiddenLabels: ["Hip Flexors", "All Hips"]
            )]
        )
        secondaryHips.acceptanceTap()
    }
}
