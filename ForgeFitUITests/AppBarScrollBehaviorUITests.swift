import XCTest

/// Two shell-level scrolling contracts: reselecting the visible tab returns
/// that screen to its top, and a row that continues past the display edge
/// looks like it does.
final class AppBarScrollBehaviorUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// SwiftUI can retain the previous tab's accessibility branch while the
    /// new root is already rendered. Resolve the visible instance so a stale
    /// proxy cannot turn a visually correct transition into a false failure.
    private func visibleElement(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: id)
        return matches.allElementsBoundByIndex.first(where: {
            $0.exists && !$0.frame.isEmpty && $0.isHittable
        }) ?? matches.firstMatch
    }

    private func launch(_ app: XCUIApplication, tab: String = "home") {
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding", "--seed-history", "--seed-starter-content",
            "-didOnboard", "YES", "-initialTab", tab,
            "-weightUnitRaw", "kg",
        ]
        app.acceptanceLaunch()
    }

    /// Waits for a condition instead of a fixed sleep, so a slow simulator
    /// costs time rather than a false failure.
    @discardableResult
    private func wait(
        timeout: TimeInterval = 5,
        until condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Scrolls the visible tab until its title header has left the screen.
    /// Returns false when the screen has too little content to scroll, which
    /// is a skip rather than a failure — a screen that fits is already at its
    /// top.
    private func scrollTitleOffScreen(_ app: XCUIApplication) -> Bool {
        let title = visibleElement(app, "screen-title")
        guard title.waitForExistence(timeout: 15) else { return false }
        for _ in 0..<6 where title.exists && title.isHittable {
            app.acceptanceSwipeUp()
        }
        return !title.isHittable
    }

    /// Reselecting the tab you are already on is the platform's "back to the
    /// top" gesture. Every tab root has to honour it.
    @MainActor
    func testReselectingTheVisibleTabScrollsItsRootToTheTop() throws {
        let app = XCUIApplication()
        launch(app)

        for tab in ["home", "workout", "insights", "profile"] {
            let tabButton = element(app, "tab-\(tab)")
            XCTAssertTrue(tabButton.waitForExistence(timeout: 15), "Missing the \(tab) tab.")
            tabButton.acceptanceTap()

            let title = visibleElement(app, "screen-title")
            XCTAssertTrue(title.waitForExistence(timeout: 10), "The \(tab) tab should render a title header.")
            guard scrollTitleOffScreen(app) else {
                // Nothing to prove on a screen whose content already fits, but
                // say so — a silently skipped tab reads as a covered one.
                XCTContext.runActivity(named: "\(tab) fits on screen; nothing to scroll back") { _ in }
                attachScreenshot(app, name: "reselect-\(tab)-fits-without-scrolling")
                continue
            }

            tabButton.acceptanceTap()
            XCTAssertTrue(
                wait { title.isHittable },
                "Reselecting the \(tab) tab should scroll its root back to the top."
            )
            attachScreenshot(app, name: "reselect-scrolled-\(tab)-to-top")
        }
    }

    /// The scroll-to-top signal is deliberately separate from tab switching:
    /// leaving a tab and coming back must return the user where they were, not
    /// silently discard their place in a long screen.
    @MainActor
    func testSwitchingAwayAndBackKeepsTheScrollPosition() throws {
        let app = XCUIApplication()
        launch(app)

        let title = visibleElement(app, "screen-title")
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        try XCTSkipUnless(scrollTitleOffScreen(app), "Home did not have enough content to scroll.")

        element(app, "tab-workout").acceptanceTap()
        XCTAssertTrue(wait { visibleElement(app, "screen-title").exists })
        element(app, "tab-home").acceptanceTap()

        XCTAssertTrue(wait { visibleElement(app, "screen-title").exists })
        XCTAssertFalse(
            visibleElement(app, "screen-title").isHittable,
            "Switching tabs should restore Home where the user left it, not scroll it to the top."
        )
    }

    /// The check-in chips do not fit, and the row has to say so with its own
    /// shape: it is bled to the display edge so a chip is cut mid-capsule
    /// rather than stopping inside the card gutter.
    @MainActor
    func testCheckinChipRowShowsItContinuesPastTheEdge() throws {
        let app = XCUIApplication()
        launch(app)

        let firstChip = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'home-checkin-'")
        ).firstMatch
        XCTAssertTrue(firstChip.waitForExistence(timeout: 15), "Home should offer the check-in chips.")

        let chips = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-checkin-'"))
        let onScreen = (0..<chips.count).map { chips.element(boundBy: $0) }.filter { $0.frame.width > 0 }
        XCTAssertGreaterThan(onScreen.count, 1, "The row should carry several chips.")

        // Something has to be cut by the display edge, otherwise the row reads
        // as a complete list of options.
        let screenWidth = app.frame.width
        let overhang = onScreen.contains { $0.frame.maxX > screenWidth - 1 }
        XCTAssertTrue(
            overhang,
            "A chip should run past the display edge so the row reads as scrollable."
        )
        attachScreenshot(app, name: "checkin-row-trailing-peek")

        // And the row must actually deliver what it advertises: the chip that
        // was cut by the edge has to come fully into view when pushed.
        guard let cutOff = onScreen.filter({ $0.frame.maxX > screenWidth - 1 }).min(by: { $0.frame.minX < $1.frame.minX }) else {
            return XCTFail("Expected a chip sliced by the display edge.")
        }
        let startX = cutOff.frame.minX
        firstChip.acceptanceSwipeLeft()
        XCTAssertTrue(
            wait { cutOff.frame.minX < startX - 1 },
            "The check-in row should scroll horizontally when pushed."
        )
        XCTAssertTrue(
            wait { cutOff.frame.maxX <= screenWidth },
            "A chip cut by the edge should be reachable in full after scrolling."
        )
        attachScreenshot(app, name: "checkin-row-scrolled")
    }
}
