import XCTest

final class DataDisplayUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testRoutineDurationUsesWorkoutMinutesAndScaledChart() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--seed-data-display-audit",
            "-didOnboard", "YES",
            "-initialTab", "workout",
        ]
        acceptanceExpect(
            ["tab-workout", "routine-card-Data Display Audit"],
            phase: .setup,
            invariants: ["The deterministic routine-history fixture is visible"]
        )
        app.acceptanceLaunch()

        let routine = app.buttons["routine-card-Data Display Audit"].firstMatch
        try acceptanceRequire(
            routine.waitForExistence(timeout: 20),
            "The data-display routine fixture did not appear"
        )
        acceptanceExpect(
            ["routine-detail", "routine-progress-duration"],
            visibleLabels: ["Data Display Audit"],
            invariants: ["Routine progress opens through the rendered library card"]
        )
        routine.acceptanceTap()

        let duration = app.buttons["routine-progress-duration"].firstMatch
        try acceptanceRequire(duration.waitForExistence(timeout: 5), "The Duration metric control is missing")
        acceptanceExpect(
            ["routine-progress-headline", "routine-progress-chart"],
            visibleLabels: ["21.9 min"],
            invariants: [
                "Duration is the latest individual logged workout, not a weekly total",
                "The chart uses minutes and a padded observed-value range rather than zero",
            ]
        )
        duration.acceptanceTap()

        let headline = app.descendants(matching: .any)["routine-progress-headline"].firstMatch
        guard acceptanceAssert(headline.exists, "The routine duration headline is missing") else { return }
        acceptanceAssert(
            headline.label == "21.9 min",
            "A 1,314-second workout must display as 21.9 min, never 21.9 hours"
        )

        let chart = app.descendants(matching: .any)["routine-progress-chart"].firstMatch
        guard acceptanceAssert(chart.exists, "The scaled routine duration chart is missing") else { return }
        acceptanceAssert(
            chart.value as? String == "Latest 21.9 min. Visible range 20 to 22.5",
            "The visible duration range should follow the observed workout values"
        )
    }
}
