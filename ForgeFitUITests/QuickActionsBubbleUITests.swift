import XCTest

/// The floating quick-action bubble: root-level chrome above the tab bar.
/// These tests pin the gesture boundaries (tap vs long-press on the trigger,
/// scrim dismissal) and the tab-agnostic action paths.
final class QuickActionsBubbleUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// Seeded prefs + forced default bubble actions, so a prior session on
    /// this simulator can't reorder the fan. Read-only tests pin the pref via
    /// the `-quickActionBubble.v1 ""` argument ("" → defaults). Tests that
    /// EDIT the actions must pass `seedDefaultActions: false`: an argument-
    /// domain value shadows every in-app write for the whole process, so they
    /// clear the stored pref via `--reset-quick-actions` instead.
    private func launchApp(initialTab: String? = nil, seedDefaultActions: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["--reset-store", "-didOnboard", "YES", "-weightUnitRaw", "kg"]
        args += seedDefaultActions ? ["-quickActionBubble.v1", ""] : ["--reset-quick-actions"]
        if let initialTab {
            args += ["-initialTab", initialTab]
        }
        app.launchArguments = args
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Liquid Glass can expose a non-hittable text/proxy node with the same
    /// identifier as its control. Interaction assertions must target the real
    /// button, otherwise XCTest eventually synthesizes a tap at {-1, -1}.
    private func button(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.buttons.matching(identifier: id).firstMatch
    }

    /// Fan bubbles hit-test only once their birth animation reveals them —
    /// existence can lead hittability by a few frames.
    private func tapWhenHittable(_ el: XCUIElement, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !el.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        el.tap()
    }

    /// The bubble is root-level chrome: it must work from any tab, not just
    /// where starting workouts feels natural. Insights is the proof.
    @MainActor
    func testFanStartsEmptyWorkoutFromInsightsTab() throws {
        let app = launchApp(initialTab: "insights")

        let trigger = button(app, "quick-actions-trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5), "Expected the quick-actions trigger on Insights.")
        trigger.tap()

        let emptyAction = button(app, "quick-action-empty")
        XCTAssertTrue(emptyAction.waitForExistence(timeout: 3), "Expected the fan to expose the empty-workout bubble.")
        tapWhenHittable(emptyAction)

        XCTAssertTrue(element(app, "finish-workout-button").waitForExistence(timeout: 5),
                      "Expected the live logger after starting an empty workout from the bubble.")
    }

    @MainActor
    func testScrimTapCollapsesFan() throws {
        let app = launchApp()

        let trigger = button(app, "quick-actions-trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()

        let scrim = button(app, "quick-actions-scrim")
        XCTAssertTrue(scrim.waitForExistence(timeout: 3), "Expected the dimmed scrim behind the open fan.")
        scrim.tap()

        // Collapse morphs the dismiss control back into the trigger — its
        // reappearance IS the collapsed state.
        XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Expected the fan to collapse on a scrim tap.")
        XCTAssertFalse(element(app, "quick-actions-scrim").exists, "Expected the scrim to unmount after collapse.")
    }

    /// Gesture boundary: a long press opens the editor WITHOUT also expanding
    /// the fan (a SwiftUI Button still fires on the touch's release, so the
    /// suppression flag must swallow it), and a plain tap afterwards still
    /// expands normally.
    @MainActor
    func testLongPressOpensEditorAndPlainTapStillExpands() throws {
        let app = launchApp()

        let trigger = button(app, "quick-actions-trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.press(forDuration: 0.8)

        let done = button(app, "quick-actions-editor-done")
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Expected the editor sheet from a trigger long-press.")
        done.tap()

        // If the hold's release had also fired the Button, the fan would be
        // open now and the trigger replaced by the dismiss control.
        XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Expected the menu still collapsed after the editor closes.")

        trigger.tap()
        XCTAssertTrue(element(app, "quick-action-empty").waitForExistence(timeout: 3),
                      "Expected a plain tap to still expand the fan after a long-press cycle.")
        tapWhenHittable(button(app, "quick-actions-dismiss"))
        XCTAssertTrue(trigger.waitForExistence(timeout: 3))
    }

    /// The "main button" gesture works in the expanded state too: holding the
    /// dismiss ✕ opens the editor, and the fan retracts behind it.
    @MainActor
    func testLongPressOnExpandedFanOpensEditor() throws {
        let app = launchApp()

        let trigger = button(app, "quick-actions-trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()

        let dismiss = button(app, "quick-actions-dismiss")
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        dismiss.press(forDuration: 0.8)

        let done = button(app, "quick-actions-editor-done")
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Expected the editor from holding the expanded dismiss control.")
        done.tap()

        // The fan collapsed behind the editor, so dismissal lands on the
        // collapsed trigger — never a stale fan.
        XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Expected the collapsed trigger after closing the editor.")
    }

    /// Inline pool add inside the always-editing List: tap a pool row, see it
    /// join the current actions, and find its bubble in the live fan after
    /// dismissing — the full customization loop.
    @MainActor
    func testInlineAddFlowsThroughToFan() throws {
        let app = launchApp(seedDefaultActions: false)

        let trigger = button(app, "quick-actions-trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.press(forDuration: 0.8)

        let poolRow = button(app, "quick-actions-pool-cardio-cycle")
        XCTAssertTrue(poolRow.waitForExistence(timeout: 3), "Expected the cardio pool row in the editor.")
        if !poolRow.isHittable { app.swipeUp() }
        poolRow.tap()

        XCTAssertTrue(element(app, "quick-actions-editor-row-cardio:cycle").waitForExistence(timeout: 3),
                      "Expected the added action to appear in the current list (pool taps must work in the editing List).")

        button(app, "quick-actions-editor-done").tap()
        XCTAssertTrue(trigger.waitForExistence(timeout: 3))
        tapWhenHittable(trigger)
        XCTAssertTrue(element(app, "quick-action-empty").waitForExistence(timeout: 3),
                      "Expected the fan to reopen after the editor.")
        XCTAssertTrue(element(app, "quick-action-cardio-cycle").waitForExistence(timeout: 3),
                      "Expected the newly added action's bubble in the live fan (store reload).")
        // Ordering contract: the editor list mirrors the fan (top row = top
        // bubble), and a pool add appends to the list bottom — nearest the
        // button — so the new bubble must sit BELOW the old nearest one.
        XCTAssertGreaterThan(
            button(app, "quick-action-cardio-cycle").frame.midY,
            button(app, "quick-action-empty").frame.midY,
            "Expected the newly added action nearest the button (bottom of the fan)."
        )
        tapWhenHittable(button(app, "quick-actions-dismiss"))
    }

    @MainActor
    func testWeightActionPresentsLogWeightSheet() throws {
        let app = launchApp()

        let trigger = button(app, "quick-actions-trigger")
        XCTAssertTrue(trigger.waitForExistence(timeout: 5))
        trigger.tap()

        let weight = button(app, "quick-action-bodyweight")
        XCTAssertTrue(weight.waitForExistence(timeout: 3))
        tapWhenHittable(weight)

        XCTAssertTrue(element(app, "log-weight-field").waitForExistence(timeout: 3),
                      "Expected the root log-weight sheet from the bubble.")
        button(app, "log-weight-cancel").tap()
        XCTAssertTrue(trigger.waitForExistence(timeout: 3), "Expected the collapsed bubble after cancelling the sheet.")
    }
}
