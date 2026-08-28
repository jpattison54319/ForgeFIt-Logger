import XCTest

/// Repeatable UI performance probes for the interaction paths that must stay
/// inside the current display's frame budget. Fixtures and navigation setup run
/// outside each measured interval; XCTest baselines can therefore be recorded
/// from repeated Release measurements without baking simulator timing into the
/// source. Raw XCUI actions are intentional here because acceptance evidence
/// capture would add screenshots and accessibility snapshots to the samples.
final class PerformanceRegressionUITests: XCTestCase {
    private let persistedArguments = [
        "--skip-onboarding",
        "--suppress-health-refresh",
        "-didOnboard", "YES",
        "-weightUnitRaw", "kg",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - Launch and shell

    /// Reproduces the reset ordering that originally left only the mini logger:
    /// launch one leaves an active @Query row behind, while launch two deletes
    /// it and commits a replacement before the old query generation settles.
    @MainActor
    func testAutoStartPresentationSurvivesResetWithStaleActiveRow() {
        let app = configuredApp(arguments: resetArguments + ["--auto-start-routine"])
        defer { app.terminate() }

        app.launch()
        XCTAssertTrue(
            button(app, "finish-workout-button").waitForExistence(timeout: 30),
            "The first fixture workout must present its logger."
        )
        app.terminate()

        app.launch()
        XCTAssertTrue(
            button(app, "finish-workout-button").waitForExistence(timeout: 30),
            "A reset replacement must present instead of stranding the stale workout in the mini bar."
        )
    }

    /// Exercises the empty-store bootstrap on every sample. This is the
    /// deterministic UI-test equivalent of a first install: SwiftData is reset
    /// while explicit defaults bypass onboarding and Health permission UI.
    @MainActor
    func testFreshStoreLaunchResponsiveness() {
        let app = configuredApp(arguments: resetArguments)
        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true),
                XCTHitchMetric(application: app),
            ],
            options: automaticOptions(iterations: 5)
        ) {
            app.launch()
            XCTAssertTrue(
                button(app, "home-calendar").waitForExistence(timeout: 20),
                "A fresh-store launch must reach an interactive Home screen."
            )
        }
        app.terminate()
    }

    @MainActor
    func testLaunchResponsivenessWithSeededHistory() {
        let bootstrap = launchApp(
            arguments: resetArguments + [
                "--seed-history",
                "--seed-home-dashboard-cache",
            ],
            readyIdentifier: "home-calendar"
        )
        bootstrap.terminate()

        let measuredApp = configuredApp(arguments: persistedArguments)
        measure(
            metrics: [
                XCTApplicationLaunchMetric(waitUntilResponsive: true),
                XCTHitchMetric(application: measuredApp),
            ],
            options: automaticOptions(iterations: 5)
        ) {
            measuredApp.launch()
            XCTAssertTrue(
                button(measuredApp, "home-calendar").waitForExistence(timeout: 20),
                "A measured launch must reach an interactive Home screen."
            )
        }
        measuredApp.terminate()
    }

    @MainActor
    func testHomeScrollingWithSeededHistory() {
        let app = launchApp(
            arguments: resetArguments + [
                "--seed-history",
                "--seed-home-dashboard-cache",
            ],
            readyIdentifier: "home-calendar"
        )
        defer { app.terminate() }

        let homeTab = button(app, "tab-home")
        let title = staticText(app, "screen-title")
        XCTAssertTrue(waitUntil { title.exists && title.isHittable })

        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTHitchMetric(application: app),
            ],
            options: manualOptions(iterations: 5)
        ) {
            homeTab.tap()
            XCTAssertTrue(
                waitUntil { title.exists && title.isHittable },
                "Each sample must begin at the top of Home."
            )
            // Reselecting Home animates the root back to the top. Keep that
            // reset animation entirely outside the measured scroll sample.
            settle(for: 0.6)

            startMeasuring()
            app.swipeUp(velocity: .fast)
            stopMeasuring()
        }

        XCTAssertFalse(title.isHittable, "The measured gesture must move Home's vertical scroll surface.")
    }

    /// ForgeFit's app bar swaps keep-resident roots directly; it is not an OS
    /// navigation-controller transition and emits no navigation signpost. Wall
    /// clock and app-target hitch metrics cover tap through destination receipt.
    @MainActor
    func testFirstWorkoutTabSelectionResponsiveness() {
        let bootstrap = launchApp(
            arguments: resetArguments + ["--seed-history"],
            readyIdentifier: "home-calendar"
        )
        bootstrap.terminate()

        let app = configuredApp(arguments: persistedArguments)
        defer { app.terminate() }
        let home = button(app, "home-calendar")
        let workoutTab = button(app, "tab-workout")
        let destination = button(app, "new-routine-button")

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
            options: manualOptions(iterations: 3)
        ) {
            app.terminate()
            app.launch()

            XCTAssertTrue(
                home.waitForExistence(timeout: 20) && waitUntil { home.isHittable },
                "Each sample must launch with only Home mounted."
            )
            settle(for: 0.35)

            startMeasuring()
            workoutTab.tap()
            let destinationReady = waitUntil(timeout: 15) {
                destination.exists && destination.isHittable
            }
            stopMeasuring()

            XCTAssertTrue(destinationReady, "The first Workout selection must become interactive.")
        }
    }

    @MainActor
    func testResidentTabSwitchResponsiveness() {
        let app = launchApp(
            arguments: resetArguments + ["--seed-history"],
            readyIdentifier: "home-calendar"
        )
        defer { app.terminate() }

        let homeTab = button(app, "tab-home")
        let workoutTab = button(app, "tab-workout")
        let homeReceipt = button(app, "home-calendar")
        let workoutReceipt = button(app, "new-routine-button")

        workoutTab.tap()
        XCTAssertTrue(waitUntil { workoutReceipt.exists && workoutReceipt.isHittable })
        homeTab.tap()
        XCTAssertTrue(waitUntil { homeReceipt.exists && homeReceipt.isHittable })

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
            options: manualOptions(iterations: 5)
        ) {
            homeTab.tap()
            XCTAssertTrue(waitUntil { homeReceipt.exists && homeReceipt.isHittable })
            // Let the tab pill and root swap finish before timing the reverse
            // transition; otherwise one sample can inherit prior animation.
            settle(for: 0.55)

            startMeasuring()
            workoutTab.tap()
            let destinationReady = waitUntil {
                workoutReceipt.exists && workoutReceipt.isHittable
            }
            stopMeasuring()

            XCTAssertTrue(destinationReady, "A resident Workout tab must become interactive.")
        }
    }

    // MARK: - Routine editor

    @MainActor
    func testRoutineEditorTypingWithSeededHistory() {
        let editor = launchRoutineEditor(includesHistory: true)
        defer { editor.app.terminate() }

        let baseline = "Long Routine"
        let typedSuffix = " Performance 123"
        XCTAssertTrue(replaceText(in: editor.nameField, with: baseline))

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: editor.app)],
            options: manualOptions(iterations: 5)
        ) {
            XCTAssertTrue(
                replaceText(in: editor.nameField, with: baseline),
                "Each sample must begin with the same routine name."
            )
            settle(for: 2.25)

            startMeasuring()
            editor.nameField.typeText(typedSuffix)
            stopMeasuring()

            XCTAssertTrue(waitUntil {
                editor.nameField.value as? String == baseline + typedSuffix
            })
        }
    }

    @MainActor
    func testRoutineEditorScrolling() {
        let editor = launchRoutineEditor(includesHistory: false)
        defer { editor.app.terminate() }

        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTHitchMetric(application: editor.app),
            ],
            options: manualOptions(iterations: 5)
        ) {
            XCTAssertTrue(
                scrollToTop(in: editor.app, sentinel: editor.nameField),
                "Each sample must return to the top of the editor."
            )
            settle(for: 0.6)

            startMeasuring()
            editor.scrollView.swipeUp(velocity: .fast)
            stopMeasuring()
        }

        XCTAssertFalse(
            editor.nameField.isHittable,
            "The measured gesture must move the long routine editor."
        )
    }

    // MARK: - Live workout

    @MainActor
    func testLiveWorkoutScrolling() {
        let app = launchLongWorkout()
        defer { app.terminate() }

        let topReceipt = button(app, "add-workout-note")
        XCTAssertTrue(
            topReceipt.waitForExistence(timeout: 20),
            "The seeded active workout must open at the top of the logger."
        )

        measure(
            metrics: [
                XCTOSSignpostMetric.scrollingAndDecelerationMetric,
                XCTHitchMetric(application: app),
            ],
            options: manualOptions(iterations: 5)
        ) {
            XCTAssertTrue(
                scrollToTop(in: app, sentinel: topReceipt),
                "Each sample must begin at the top of the logger."
            )
            // Visibility alone can occur a few points below the real top.
            // One final reset gesture plus a settle gives every sample the
            // same starting offset and excludes its bounce/deceleration.
            app.swipeDown(velocity: .fast)
            settle(for: 0.6)

            startMeasuring()
            app.swipeUp(velocity: .fast)
            stopMeasuring()
        }

        XCTAssertFalse(topReceipt.isHittable, "The measured gesture must move the live logger.")
    }

    @MainActor
    func testLiveSetCompletionResponsiveness() {
        let app = launchLongWorkout()
        defer { app.terminate() }

        let firstSet = firstSetCompletionButton(in: app)
        let firstReps = app.textFields["Reps"].firstMatch
        revealLiveSet([firstSet, firstReps], in: app)
        XCTAssertTrue(replaceText(in: firstReps, with: "10"))
        dismissKeyboardIfVisible(in: app)

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
            options: manualOptions(iterations: 5)
        ) {
            if firstSet.label == "Mark set incomplete" {
                firstSet.tap()
            }
            XCTAssertTrue(waitUntil {
                firstSet.exists && firstSet.label == "Mark set complete"
            })
            // Set edits share a two-second save debounce. Let any setup write
            // settle so persistence from one iteration cannot land inside the
            // next completion sample.
            settle(for: 2.25)

            startMeasuring()
            firstSet.tap()
            let completionVisible = waitUntil {
                firstSet.exists && firstSet.label == "Mark set incomplete"
            }
            stopMeasuring()

            XCTAssertTrue(completionVisible, "The completion checkmark must update in the interaction turn.")
        }
    }

    /// Measures the interaction users repeat most often while logging: replace
    /// the visible load and reps in one set. The field reset and save debounce
    /// are outside the sample so only focus, deletion, and typed draft renders
    /// contribute to the result.
    @MainActor
    func testLiveSetFieldTypingResponsiveness() {
        let app = launchLongWorkout()
        defer { app.terminate() }

        let weight = app.textFields["Weight"].firstMatch
        let reps = app.textFields["Reps"].firstMatch
        revealLiveSet([weight, reps], in: app)

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
            options: manualOptions(iterations: 5)
        ) {
            XCTAssertTrue(replaceText(in: weight, with: "50"))
            XCTAssertTrue(replaceText(in: reps, with: "10"))
            settle(for: 2.25)

            startMeasuring()
            let weightChanged = replaceText(in: weight, with: "62.5")
            let repsChanged = replaceText(in: reps, with: "12")
            stopMeasuring()

            XCTAssertTrue(weightChanged && repsChanged, "Weight and reps must keep every typed character.")
        }
    }

    /// Uses the compact starter workout so setup can complete its only set and
    /// isolate the real terminal transition, without measuring 31 unrelated
    /// completion taps or the unfinished-work confirmation alert.
    @MainActor
    func testFinishToSummaryResponsiveness() {
        let app = launchApp(
            arguments: resetArguments + ["--auto-start-routine"],
            readyIdentifier: "finish-workout-button",
            timeout: 30
        )
        defer { app.terminate() }

        let complete = firstSetCompletionButton(in: app)
        let finish = button(app, "finish-workout-button")
        let summary = button(app, "save-workout-button")
        let keepLogging = button(app, "post-workout-keep-logging-button")

        XCTAssertTrue(complete.waitForExistence(timeout: 15))
        complete.tap()
        XCTAssertTrue(waitUntil { complete.label == "Mark set incomplete" })
        settle(for: 2.25)

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
            options: manualOptions(iterations: 5)
        ) {
            if summary.exists {
                keepLogging.tap()
            }
            XCTAssertTrue(waitUntil { finish.exists && finish.isHittable })
            settle(for: 0.45)

            startMeasuring()
            finish.tap()
            let summaryReady = waitUntil(timeout: 15) {
                summary.exists && summary.isHittable
            }
            stopMeasuring()

            XCTAssertTrue(summaryReady, "Finish must present an interactive post-workout summary.")
        }
    }

    /// Measures the terminal persistence boundary itself. Each sample creates
    /// the deterministic 8-exercise/30+-set fixture outside the measured
    /// interval, logs one concrete set, advances through the unfinished-work
    /// decision, then times Save Workout through logger dismissal.
    @MainActor
    func testTerminalSaveDismissResponsiveness() {
        let app = configuredApp(arguments: resetArguments + [
            "--seed-history",
            "--seed-routine-hierarchy-many-exercises",
            "--auto-start-routine",
        ])
        defer { app.terminate() }

        measure(
            metrics: [XCTClockMetric(), XCTHitchMetric(application: app)],
            options: manualOptions(iterations: 3)
        ) {
            app.terminate()
            app.launch()

            let finish = button(app, "finish-workout-button")
            let complete = firstSetCompletionButton(in: app)
            let reps = app.textFields["Reps"].firstMatch
            XCTAssertTrue(finish.waitForExistence(timeout: 60))
            revealLiveSet([complete, reps], in: app)
            XCTAssertTrue(replaceText(in: reps, with: "10"))
            dismissKeyboardIfVisible(in: app)
            complete.tap()
            XCTAssertTrue(waitUntil { complete.label == "Mark set incomplete" })
            settle(for: 2.25)

            finish.tap()
            let finishAnyway = app.buttons["Finish Anyway"].firstMatch
            if finishAnyway.waitForExistence(timeout: 5) {
                finishAnyway.tap()
            }
            let save = button(app, "save-workout-button")
            XCTAssertTrue(save.waitForExistence(timeout: 15) && waitUntil { save.isHittable })
            settle(for: 0.45)

            startMeasuring()
            save.tap()
            let dismissed = waitUntil(timeout: 20) {
                button(app, "tab-home").isHittable
                    && !button(app, "finish-workout-button").exists
                    && !button(app, "expand-active-workout").exists
            }
            stopMeasuring()

            XCTAssertTrue(dismissed, "Terminal Save must persist and dismiss the live logger.")
        }
    }

    // MARK: - Fixtures and measurement support

    private var resetArguments: [String] {
        persistedArguments + ["--reset-store"]
    }

    private func configuredApp(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        return app
    }

    @MainActor
    private func launchApp(
        arguments: [String],
        readyIdentifier: String,
        timeout: TimeInterval = 30
    ) -> XCUIApplication {
        let app = configuredApp(arguments: arguments)
        app.launch()
        let ready = button(app, readyIdentifier)
        XCTAssertTrue(
            ready.waitForExistence(timeout: timeout) && waitUntil(timeout: 5) { ready.isHittable },
            "The fixture did not expose \(readyIdentifier)."
        )
        return app
    }

    @MainActor
    private func launchRoutineEditor(
        includesHistory: Bool
    ) -> (app: XCUIApplication, nameField: XCUIElement, scrollView: XCUIElement) {
        var arguments = resetArguments + [
            "--seed-routine-hierarchy-many-exercises",
            "-initialTab", "workout",
        ]
        if includesHistory {
            arguments.append("--seed-history")
        }

        let app = launchApp(
            arguments: arguments,
            readyIdentifier: "routine-menu-Long Routine",
            timeout: includesHistory ? 45 : 30
        )
        let menu = app.buttons["routine-menu-Long Routine"].firstMatch
        menu.tap()

        let edit = app.buttons["Edit Long Routine"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()

        let scroll = app.scrollViews["routine-editor-scroll"].firstMatch
        let name = app.textFields["Routine name"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 10))
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        return (app, name, scroll)
    }

    @MainActor
    private func launchLongWorkout() -> XCUIApplication {
        launchApp(
            arguments: resetArguments + [
                "--seed-history",
                "--seed-routine-hierarchy-many-exercises",
                "--auto-start-routine",
            ],
            // The Finish action is unique and proves the logger presentation
            // is mounted. Set identifiers intentionally repeat per exercise.
            readyIdentifier: "finish-workout-button",
            timeout: 60
        )
    }

    private func button(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.buttons[identifier].firstMatch
    }

    /// iOS 26 can omit a SwiftUI button's identifier from the XCUI snapshot
    /// while still exposing its explicit accessibility label. Match both so
    /// the performance interval measures the interaction instead of failing
    /// during off-clock fixture navigation.
    private func firstSetCompletionButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR label == %@",
            "complete-set-1",
            "Mark set complete",
            "Mark set incomplete"
        )).firstMatch
    }

    private func staticText(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.staticTexts[identifier].firstMatch
    }

    private func revealLiveSet(_ elements: [XCUIElement], in app: XCUIApplication) {
        for _ in 0..<6 where !elements.allSatisfy({ $0.exists && $0.isHittable }) {
            app.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(
            waitUntil(timeout: 10) { elements.allSatisfy { $0.exists && $0.isHittable } },
            "The long-workout fixture must expose its first live set after scrolling."
        )
    }

    private func dismissKeyboardIfVisible(in app: XCUIApplication) {
        let dismiss = app.buttons["Dismiss keyboard"].firstMatch
        if dismiss.exists && dismiss.isHittable {
            dismiss.tap()
            _ = waitUntil { !app.keyboards.firstMatch.exists }
        }
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 8,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while !condition() && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        return condition()
    }

    @discardableResult
    private func scrollToTop(in app: XCUIApplication, sentinel: XCUIElement) -> Bool {
        for _ in 0..<16 where !sentinel.isHittable {
            // Start above the floating bar and drag within the app's stable
            // screen coordinates. `swipeDown` occasionally begins on a lazy
            // row control and is treated as a tap on iOS 26 automation.
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            start.press(forDuration: 0.03, thenDragTo: end)
        }
        return waitUntil { sentinel.exists && sentinel.isHittable }
    }

    private func settle(for duration: TimeInterval) {
        RunLoop.current.run(until: Date.now.addingTimeInterval(duration))
    }

    @discardableResult
    private func replaceText(in field: XCUIElement, with replacement: String) -> Bool {
        guard waitUntil(condition: { field.exists && field.isHittable }) else { return false }
        field.tap()
        // iOS 26 can drop Command-A and can also ignore isolated hardware
        // Delete events. Re-read after each software-keyboard delete burst;
        // this is the proven bounded clear pattern used by the acceptance suite.
        for _ in 0..<6 {
            guard let current = field.value as? String,
                  !current.isEmpty,
                  !current.hasPrefix("Suggested "),
                  current != field.placeholderValue else { break }
            // A center tap can leave the caret in the middle of a long value;
            // after SwiftUI publishes the shortened draft it may reset to the
            // beginning, where further Backspace events are no-ops.
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
            field.typeText(
                String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count)
            )
        }
        let remaining = field.value as? String ?? ""
        guard remaining.isEmpty
                || remaining == field.placeholderValue
                || remaining.hasPrefix("Suggested ") else { return false }
        if !replacement.isEmpty {
            field.typeText(replacement)
        }
        return waitUntil { field.value as? String == replacement }
    }

    private func automaticOptions(iterations: Int) -> XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations
        return options
    }

    private func manualOptions(iterations: Int) -> XCTMeasureOptions {
        let options = automaticOptions(iterations: iterations)
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        return options
    }
}
