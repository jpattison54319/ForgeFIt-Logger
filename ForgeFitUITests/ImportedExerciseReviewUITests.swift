import XCTest

final class ImportedExerciseReviewUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testIndividualDiscardIsExplainedAndRemovesOnlyThatLibraryExercise() throws {
        let app = launch()
        try openReview(in: app)

        acceptanceAssert(app.staticTexts["New exercise suggestions"].exists, "The review does not explain why these exercises need attention")
        let explanation = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "These suggestions are not workout scores.")
        ).firstMatch
        acceptanceAssert(explanation.exists, "The review does not explain that its suggestions are not workout scores")
        acceptanceAssert(app.buttons["Merge"].exists == false, "Merge must not be offered during imported-exercise review")
        acceptanceAssert(app.staticTexts["AI"].exists == false, "Implementation-source jargon must not be shown to the user")
        acceptanceAssert(app.staticTexts["80%"].exists == false, "Internal classifier confidence must not look like a user-facing score")

        let discard = app.buttons["Discard Lat Prayer"].firstMatch
        try reveal(discard, in: app)
        acceptanceExpect(
            visibleLabels: ["Discard exercise", "Cancel"],
            invariants: ["Discard opens a cancellable consequence confirmation before changing the library"]
        )
        discard.acceptanceTap()

        let confirm = app.buttons["Discard exercise"].firstMatch
        try acceptanceRequire(confirm.waitForExistence(timeout: 3), "The discard consequence confirmation did not appear")
        try acceptanceRequire(app.buttons["Cancel"].waitForExistence(timeout: 3), "The discard confirmation does not offer a clear way back")
        acceptanceExpect(
            visibleLabels: ["2 new exercises"],
            invariants: ["Only Lat Prayer leaves the review after confirmation; imported history remains unchanged"]
        )
        confirm.acceptanceTap()

        try acceptanceRequire(
            app.staticTexts["2 new exercises"].waitForExistence(timeout: 3),
            "The review count did not decrease after discarding one exercise"
        )
        acceptanceAssert(app.buttons["Discard Lat Prayer"].exists == false, "The discarded exercise stayed in the review list")
        acceptanceAssert(app.buttons["Discard Lean Back Abduction Machine"].exists, "Discarding one exercise removed another review item")
    }

    @MainActor
    func testApproveAllCompletesTheReview() throws {
        let app = launch()
        try openReview(in: app)

        let approveAll = app.buttons["approve-all-imported-exercises"].firstMatch
        try acceptanceRequire(approveAll.waitForExistence(timeout: 3), "Approve all is missing")
        acceptanceExpect(
            ["imported-exercise-review-complete"],
            invariants: ["One top-level action approves every suggestion and clears the review"]
        )
        approveAll.acceptanceTap()

        try acceptanceRequire(
            app.descendants(matching: .any)["imported-exercise-review-complete"].waitForExistence(timeout: 3),
            "Bulk approval did not complete the review"
        )
        acceptanceAssert(app.buttons["Approve all"].exists == false, "Approve all remained after every item was approved")
    }

    @MainActor
    func testDiscardAllExplainsConsequencesAndCompletesTheReview() throws {
        let app = launch()
        try openReview(in: app)

        let discardAll = app.buttons["discard-all-imported-exercises"].firstMatch
        try acceptanceRequire(discardAll.waitForExistence(timeout: 3), "Discard all is missing")
        acceptanceExpect(
            visibleLabels: ["Discard 3 exercises", "Cancel"],
            invariants: ["Bulk discard opens a cancellable confirmation before changing the library"]
        )
        discardAll.acceptanceTap()

        let confirm = app.buttons["Discard 3 exercises"].firstMatch
        try acceptanceRequire(confirm.waitForExistence(timeout: 3), "The bulk-discard confirmation did not appear")
        try acceptanceRequire(app.buttons["Cancel"].waitForExistence(timeout: 3), "The bulk-discard confirmation does not offer a clear way back")
        acceptanceExpect(
            ["imported-exercise-review-complete"],
            invariants: ["The confirmed bulk discard clears the library review while imported history remains"]
        )
        confirm.acceptanceTap()

        try acceptanceRequire(
            app.descendants(matching: .any)["imported-exercise-review-complete"].waitForExistence(timeout: 3),
            "Bulk discard did not complete the review"
        )
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--seed-imported-exercise-review",
            "-didOnboard", "YES",
            "-initialTab", "profile",
            "-weightUnitRaw", "lb",
        ]
        acceptanceExpect(
            ["profile-imported-exercise-review"],
            phase: .setup,
            invariants: ["A deterministic three-exercise import batch appears on Profile"]
        )
        app.acceptanceLaunch()
        return app
    }

    @MainActor
    private func openReview(in app: XCUIApplication) throws {
        let entry = app.buttons["profile-imported-exercise-review"].firstMatch
        try acceptanceRequire(entry.waitForExistence(timeout: 8), "The imported-exercise review entry did not appear on Profile")
        try reveal(entry, in: app)
        acceptanceExpect(
            ["imported-exercise-review-header", "imported-exercise-review-summary"],
            visibleLabels: ["Review Imported Exercises", "New exercise suggestions"],
            invariants: ["The destination explains why the new exercises exist and exposes both bulk decisions"]
        )
        entry.acceptanceTap()

        try acceptanceRequire(
            app.descendants(matching: .any)["imported-exercise-review-summary"].waitForExistence(timeout: 5),
            "The imported-exercise review screen did not open"
        )
        acceptanceAssert(app.staticTexts["Review Imported Exercises"].exists, "The destination title is unclear")
        acceptanceAssert(app.buttons["Approve all"].exists, "Approve all is not available at the top level")
        acceptanceAssert(app.buttons["Discard all"].exists, "Discard all is not available at the top level")
        for hiddenChromeID in ["quick-actions-trigger", "quick-actions-edit", "tab-home", "tab-workout", "tab-insights", "tab-profile"] {
            acceptanceAssert(
                app.descendants(matching: .any)[hiddenChromeID].exists == false,
                "Focused review exposes hidden app chrome to accessibility: \(hiddenChromeID)"
            )
        }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        var remainingSwipes = 4
        while !element.isHittable, remainingSwipes > 0 {
            acceptanceExpect(invariants: ["Scrolling reveals the next explicit review action"])
            app.acceptanceSwipeUp(velocity: .fast)
            remainingSwipes -= 1
        }
        try acceptanceRequire(element.isHittable, "The expected review action could not be reached by scrolling")
    }
}
