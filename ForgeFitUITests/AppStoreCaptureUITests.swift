import XCTest

/// App Store capture harness.
///
/// These are not assertions about product behavior — they are a scripted tour
/// that drives the real app so the marketing screenshots and preview videos
/// show the shipping UI rather than a mockup. `--seed-appstore-demo` supplies
/// the account (see `AppStoreDemoSeed`).
///
/// Screenshots are attached to the xcresult and exported with
/// `xcrun xcresulttool export attachments`. Preview videos are recorded from
/// the host with `simctl io recordVideo` while the `testPreview…` tours run;
/// each tour is paced so the recording needs only trimming, not editing.
final class AppStoreCaptureUITests: XCTestCase {

    override func setUpWithError() throws {
        // A capture run should produce everything it can even if one screen
        // moves; a missing shot is obvious on review.
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Launch

    /// `resetStore: false` reuses the account an earlier capture already
    /// seeded. The seed is idempotent, and skipping the reset avoids the
    /// account-reset notification that re-arms the onboarding cover — a race
    /// that costs a screenshot but *ruins* a video, because the relaunch it
    /// forces lands inside the recording.
    @discardableResult
    private func launchDemoApp(
        extraArguments: [String] = [],
        resetStore: Bool = true
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--mock-social",
            resetStore ? "--reset-store" : "--discard-active-workouts",
            "--skip-onboarding",
            "--seed-appstore-demo",
            "--seed-recovery-demo",
            "-didOnboard", "YES",
            "-weightUnitRaw", "lb",
            "-distanceUnitRaw", "mi",
            "-profileDisplayName", "Jordan",
        ] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.buttons["tab-home"].firstMatch.waitForExistence(timeout: 60),
            "The app never reached its tab shell."
        )

        // The launch seed inserts ~110 workouts and then Home's analytics
        // worker computes readiness, strain, and training load off them. Every
        // capture screen reads those results, so the tour waits once here
        // rather than racing a loading state on each screen.
        settle(20)

        // `--reset-store` occasionally re-arms the onboarding cover *after*
        // the shell has already rendered, and a tour that runs behind the
        // welcome screen records 30 seconds of nothing. Relaunching clears it;
        // tapping through it would not, because dismissing onboarding also
        // clears the starter slate this fixture depends on.
        for _ in 0..<2 where app.buttons["onboarding-get-started"].firstMatch.exists {
            app.terminate()
            app.launch()
            _ = app.buttons["tab-home"].firstMatch.waitForExistence(timeout: 60)
            settle(20)
        }
        XCTAssertFalse(
            app.buttons["onboarding-get-started"].firstMatch.exists,
            "Onboarding covered the capture run."
        )
        return app
    }

    // MARK: - Primitives

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The live logger renders a very deep hierarchy, and an untyped
    /// `descendants(matching: .any)` query over it takes long enough to trip
    /// XCTest's own snapshot timeout. Every lookup therefore walks typed
    /// queries — which the accessibility server can answer from an index —
    /// and only falls back to the full tree as a last resort.
    private func element(
        _ app: XCUIApplication,
        _ identifier: String,
        allowDeepSearch: Bool = true
    ) -> XCUIElement? {
        let queries: [XCUIElementQuery] = [
            app.buttons, app.otherElements, app.staticTexts, app.images, app.cells, app.switches,
        ]
        for query in queries {
            let candidate = query[identifier].firstMatch
            if candidate.exists { return candidate }
        }
        guard allowDeepSearch else { return nil }
        let anyMatch = app.descendants(matching: .any)[identifier].firstMatch
        return anyMatch.exists ? anyMatch : nil
    }

    @discardableResult
    private func tap(
        _ app: XCUIApplication,
        _ identifier: String,
        timeout: TimeInterval = 8,
        allowDeepSearch: Bool = false
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let target = element(app, identifier, allowDeepSearch: allowDeepSearch), target.isHittable {
                target.tap()
                return true
            }
            settle(0.4)
        } while Date() < deadline
        return false
    }

    @discardableResult
    private func tapText(_ app: XCUIApplication, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: timeout), button.isHittable {
            button.tap()
            return true
        }
        let text = app.staticTexts[label].firstMatch
        guard text.waitForExistence(timeout: 1), text.isHittable else { return false }
        text.tap()
        return true
    }

    private func dumpTree(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = "tree-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// A deliberately slow swipe. The default `swipeUp()` flings the list and
    /// the resulting video reads as a blur; a preview should scroll at reading
    /// speed.
    ///
    /// This uses `swipeUp(velocity:)` rather than a coordinate press-and-drag:
    /// a press-drag that begins on top of a control is still delivered as a
    /// tap, which is how a scroll over the Insights records list kept opening
    /// the "Estimated 1RM" info sheet and stalling the rest of the tour.
    /// `distance` is retained for call sites that want a shorter nudge; it
    /// scales the swipe velocity, since XCTest fixes the swipe's travel.
    private func slowScroll(_ app: XCUIApplication, distance: CGFloat = 0.45) {
        let velocity = XCUIGestureVelocity(rawValue: Double(max(0.2, distance)) * 700)
        app.swipeUp(velocity: velocity)
    }

    /// Scrolls until the target is both on screen and clear of the floating
    /// tab bar, which overlays the bottom of every scrolling tab.
    @discardableResult
    private func scrollToAndTap(_ app: XCUIApplication, _ identifier: String, maxSwipes: Int = 8) -> Bool {
        let safeBottom = app.frame.height * 0.88
        for _ in 0..<maxSwipes {
            if let target = element(app, identifier, allowDeepSearch: true),
               target.isHittable,
               target.frame.midY < safeBottom {
                target.tap()
                return true
            }
            slowScroll(app, distance: 0.4)
            settle(0.8)
        }
        return false
    }

    /// Matches on `BEGINSWITH` rather than equality: SwiftUI merges a
    /// `NavigationLink`'s children into one accessibility element, so a row
    /// whose visible text is "See all workouts" can surface with a longer
    /// combined label.
    @discardableResult
    private func scrollToAndTapText(_ app: XCUIApplication, _ label: String, maxSwipes: Int = 8) -> Bool {
        let safeBottom = app.frame.height * 0.88
        let predicate = NSPredicate(format: "label BEGINSWITH %@", label)
        for _ in 0..<maxSwipes {
            let queries: [XCUIElementQuery] = [
                app.buttons, app.links, app.staticTexts, app.otherElements,
                app.descendants(matching: .any),
            ]
            for query in queries {
                let candidate = query.matching(predicate).firstMatch
                guard candidate.exists, candidate.isHittable, candidate.frame.midY < safeBottom else { continue }
                candidate.tap()
                return true
            }
            slowScroll(app, distance: 0.4)
            settle(0.8)
        }
        return false
    }

    /// Re-tapping the current tab bumps its root request, which pops any
    /// pushed screen and returns the scroll to the top. The tour relies on
    /// that instead of a back button: each capture then starts from a known
    /// offset rather than wherever the previous screen left the list.
    private func resetTab(_ app: XCUIApplication, _ tab: String) {
        _ = tap(app, "tab-\(tab)")
        settle(1.2)
        _ = tap(app, "tab-\(tab)")
        settle(1.8)
    }

    /// The app draws its own circular back control (`chevron.left`, labelled
    /// "Back") rather than a `UINavigationBar` item, so the usual
    /// `navigationBars.buttons` route finds nothing on most screens. Falls back
    /// to the interactive-pop edge swipe rather than failing the run.
    private func back(_ app: XCUIApplication) {
        if tap(app, "exercise-detail-back", timeout: 0.5) { return }
        if tap(app, "chevron.left", timeout: 1.5) { return }

        let navBack = app.navigationBars.buttons.element(boundBy: 0)
        if navBack.exists, navBack.isHittable {
            navBack.tap()
            return
        }
        let labelled = app.buttons["Back"].firstMatch
        if labelled.exists, labelled.isHittable {
            labelled.tap()
            return
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                withVelocity: .default,
                thenHoldForDuration: 0
            )
    }

    // MARK: - Screenshots

    // Each section is its own test with its own launch. Chaining every screen
    // through one long session made later shots depend on whether an earlier
    // back-navigation landed, which is exactly the kind of order dependence
    // that produced silently-missing assets.

    /// 01–03 — Home, and the two cards that explain it.
    func testCaptureHome() throws {
        let app = launchDemoApp()

        shoot("01-home-readiness")

        if tap(app, "home-recovery-card") {
            settle(3)
            shoot("02-recovery-detail")
            back(app)
            settle(2)
        }

        if tap(app, "home-sleep-card") {
            settle(3)
            shoot("03-sleep-detail")
        }
    }

    /// 05–06 — The plan, and what the training adds up to.
    func testCaptureTrainAndInsights() throws {
        let app = launchDemoApp()

        if tap(app, "tab-workout") {
            settle(3)
            shoot("05-routines")
        }

        if tap(app, "tab-insights") {
            settle(3.5)
            shoot("06-insights")
            slowScroll(app, distance: 0.4)
            settle(2)
            shoot("06b-insights-records")
        }
    }

    /// 08–09, 12 — Profile, calendar rings, statistics.
    func testCaptureProfile() throws {
        let app = launchDemoApp()

        guard tap(app, "tab-profile") else { return }
        settle(3)
        shoot("08-profile")

        if scrollToAndTapText(app, "Calendar", maxSwipes: 4) {
            settle(4)
            shoot("09-calendar")
            back(app)
            settle(2)
        }

        if scrollToAndTapText(app, "Statistics", maxSwipes: 4) {
            settle(4)
            shoot("12-statistics")
            slowScroll(app, distance: 0.4)
            settle(2)
            shoot("12b-statistics-scrolled")
        }
    }

    /// 13, 07 — The exercise library, and one lift's history.
    func testCaptureExerciseDetail() throws {
        let app = launchDemoApp()

        guard tap(app, "tab-profile") else { return }
        settle(2.5)
        guard scrollToAndTap(app, "profile-exercises", maxSwipes: 5) else {
            shoot("dbg-no-exercises-tile")
            return
        }
        settle(3.5)
        shoot("13-exercise-library")

        // 915 rows: search rather than swipe.
        let search = app.searchFields.firstMatch.exists
            ? app.searchFields.firstMatch
            : app.textFields.firstMatch
        if search.waitForExistence(timeout: 5) {
            search.tap()
            search.typeText("Barbell Squat")
            settle(2.5)
        }
        // The exercise rows expose no identifier of their own — SwiftUI merges
        // each NavigationLink into one element labelled "<name>, <muscle> ·
        // <equipment>". The trailing comma keeps "Barbell Squat" from matching
        // "Barbell Squat To A Bench".
        if scrollToAndTapText(app, "Barbell Squat,", maxSwipes: 4) {
            settle(4)
            shoot("07-exercise-detail")
            slowScroll(app, distance: 0.35)
            settle(2)
            shoot("07b-exercise-detail-scrolled")
        } else {
            shoot("dbg-exercise-search")
            dumpTree(app, "exercise-search")
        }
    }

    /// 10–11 — Searchable history, and a cardio session opened from it.
    func testCaptureHistoryAndCardio() throws {
        let app = launchDemoApp()

        guard tap(app, "tab-profile") else { return }
        settle(2.5)
        guard scrollToAndTap(app, "profile-see-all-workouts", maxSwipes: 14) else {
            shoot("dbg-profile-no-see-all")
            dumpTree(app, "profile-bottom")
            return
        }
        settle(4)
        shoot("10-history")

        if tap(app, "history-filter-row", timeout: 5) {
            settle(3)
            shoot("10b-history-filters")
            back(app)
            settle(2)
        }
        if scrollToAndTap(app, "history-workout-Row Intervals", maxSwipes: 6) {
            settle(4)
            shoot("11-cardio-detail")
            slowScroll(app, distance: 0.4)
            settle(2)
            shoot("11b-cardio-zones")
        } else {
            shoot("dbg-no-cardio-row")
        }
    }

    /// The logger lives in its own capture run: it presents over the tab shell
    /// and its hierarchy is deep enough that leaving it and continuing the
    /// tour costs more time than relaunching does.
    func testCaptureLoggerScreenshots() throws {
        let app = launchDemoApp(extraArguments: ["--seed-active-workout"])

        guard tap(app, "expand-active-workout", timeout: 15) else {
            XCTFail("No active workout to open — the --seed-active-workout fixture did not run.")
            return
        }
        settle(4)
        shoot("04-live-logger")
        slowScroll(app, distance: 0.35)
        settle(2)
        shoot("04b-live-logger-scrolled")
    }

    // MARK: - Preview videos
    //
    // Each tour is budgeted to run roughly 28 seconds of visible choreography
    // and to *end* on its closing shot. The host records the whole session and
    // keeps only the last 28 seconds (`ffmpeg -sseof`), which sidesteps having
    // to guess when the build, install, and launch finished — and lands inside
    // App Store Connect's 15–30 s preview window.

    /// Preview 1 — the daily loop: readiness, then train.
    func testPreviewTourTrain() throws {
        // Start the preview sequence from a clean store. A prior screenshot
        // capture deliberately leaves a seeded workout active; reusing that
        // state opens the destructive "Discard Current & Start New" sheet in
        // the recording instead of starting the routine.
        let app = launchDemoApp()
        // Open on the readiness dashboard and let it read; the *why* behind
        // the score is preview 2's job, so this tour stays on the daily loop
        // and keeps its whole arc inside the 30-second ceiling.
        settle(4)
        slowScroll(app, distance: 0.3)
        settle(3)

        _ = tap(app, "tab-workout")
        settle(3)
        _ = tap(app, "start-routine-Push Day")
        if app.buttons["Discard Current & Start New"].firstMatch.waitForExistence(timeout: 2) {
            app.buttons["Discard Current & Start New"].firstMatch.tap()
        }
        settle(3)

        // Log the opening sets at a readable pace.
        for setNumber in 1...3 {
            _ = tap(app, "complete-set-\(setNumber)", timeout: 5)
            settle(2)
        }
        slowScroll(app, distance: 0.35)
        settle(1.5)
        _ = tap(app, "complete-set-1", timeout: 4)
        settle(2.5)
    }

    /// Preview 2 — recovery depth: the numbers behind the number.
    func testPreviewTourRecover() throws {
        let app = launchDemoApp(resetStore: false)
        settle(1.5)

        _ = tap(app, "home-recovery-card")
        settle(4)
        back(app)
        settle(1.5)

        _ = tap(app, "home-sleep-card")
        settle(3.5)
        slowScroll(app, distance: 0.3)
        settle(2)
        back(app)
        settle(1.5)

        _ = tap(app, "tab-profile")
        settle(2.5)
        _ = scrollToAndTapText(app, "Calendar", maxSwipes: 4)
        settle(4)
    }

    /// Preview 3 — progress: profile, charts, muscle balance, and records.
    func testPreviewTourProgress() throws {
        let app = launchDemoApp(resetStore: false)
        settle(2)

        // Keep the tour on dashboards whose seeded summaries are ready at
        // launch. The full History index is intentionally built on demand and
        // can spend most of a 30-second preview showing a loading state on a
        // cold simulator, even though the populated screen is captured as a
        // dedicated product-page screenshot.
        _ = tap(app, "tab-profile")
        settle(4)
        slowScroll(app, distance: 0.3)
        settle(3.5)

        _ = tap(app, "tab-insights")
        settle(4)
        slowScroll(app, distance: 0.3)
        settle(3.5)
        slowScroll(app, distance: 0.3)
        settle(3.5)
    }
}
