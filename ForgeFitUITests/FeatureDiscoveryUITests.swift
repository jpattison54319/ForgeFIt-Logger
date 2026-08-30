import XCTest

final class FeatureDiscoveryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testEarnedMicrocycleOfferOpensCancelsAndDismissesPermanently() throws {
        let app = launch()
        let card = app.descendants(matching: .any)["feature-discovery-microcycle-card"].firstMatch
        try acceptanceRequire(card.waitForExistence(timeout: 10), "Expected the earned Home suggestion.")
        let accept = app.descendants(matching: .any)["feature-discovery-microcycle-accept"].firstMatch
        scrollToHittable(accept, in: app)
        acceptanceExpect(
            ["start-microcycle"],
            visibleLabels: ["7 days, Day target", "Start date", "Start Tracking", "Cancel"],
            invariants: ["The suggestion explains why it is relevant, then opens the normal explicit setup flow."]
        )
        accept.acceptanceTap()
        try acceptanceRequire(
            app.navigationBars["Strength Cycle"].waitForExistence(timeout: 5),
            "Expected the existing microcycle setup flow."
        )
        acceptanceExpect(
            ["feature-discovery-microcycle-card", "feature-discovery-microcycle-dismiss"],
            visibleLabels: ["Track your microcycle", "Set day target"],
            invariants: ["Cancelling setup does not count as adoption or dismissal."]
        )
        app.buttons["Cancel"].acceptanceTap()
        try acceptanceRequire(
            card.waitForExistence(timeout: 5),
            "Cancelling setup must leave the earned suggestion available."
        )
        let dismiss = app.descendants(matching: .any)["feature-discovery-microcycle-dismiss"].firstMatch
        scrollToHittable(dismiss, in: app)
        acceptanceExpect(
            visibleLabels: ["Quick start"],
            invariants: ["Permanent dismissal removes the suggestion without disrupting the rest of Home."]
        )
        dismiss.acceptanceTap()
        acceptanceAssert(
            card.waitForNonExistence(timeout: 5),
            "Expected permanent dismissal to remove the card immediately."
        )

        app.terminate()
        app.launchArguments = app.launchArguments.filter {
            $0 != "--reset-store" && $0 != "--seed-feature-discovery-microcycle"
        }
        acceptanceExpect(
            visibleLabels: ["Quick start"],
            invariants: ["The permanently dismissed suggestion stays absent after relaunch."]
        )
        app.acceptanceLaunch()
        XCTAssertFalse(card.waitForExistence(timeout: 3))
    }

    @MainActor
    func testStartingFromEarnedOfferReplacesItWithActiveMicrocycleCard() throws {
        let app = launch()
        let accept = app.descendants(matching: .any)["feature-discovery-microcycle-accept"].firstMatch
        try acceptanceRequire(accept.waitForExistence(timeout: 10), "Expected the earned action.")
        scrollToHittable(accept, in: app)
        acceptanceExpect(
            ["start-microcycle"],
            visibleLabels: ["Strength Cycle", "Set day target"],
            invariants: ["The explicit action opens setup before tracking begins."]
        )
        accept.acceptanceTap()

        let start = app.buttons["start-microcycle"].firstMatch
        try acceptanceRequire(start.waitForExistence(timeout: 5), "Expected Start Tracking.")
        acceptanceExpect(
            ["home-microcycle-card"],
            visibleLabels: ["Strength Cycle"],
            invariants: ["Successful setup removes the discovery offer and publishes the normal active microcycle card."]
        )
        start.acceptanceTap()

        XCTAssertTrue(app.descendants(matching: .any)["home-microcycle-card"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["feature-discovery-microcycle-card"].exists)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--seed-feature-discovery-microcycle",
            "-didOnboard", "YES",
            "-initialTab", "home",
            "-weightUnitRaw", "kg",
        ]
        acceptanceExpect(
            ["feature-discovery-microcycle-card"],
            invariants: ["Three post-enrollment routine workouts earn one unobtrusive Home suggestion."]
        )
        app.acceptanceLaunch()
        return app
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval = 20
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !(element.exists && element.isHittable), Date() < deadline {
            app.acceptanceSwipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
