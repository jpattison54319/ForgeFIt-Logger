import XCTest

final class AppIntentRoutingUITests: XCTestCase {
    private let starterIntentURL =
        "forgefit://start-choice?id=routine%3A00000000-0000-7000-8000-000000000910"

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testChosenRoutineStartsThroughTheRenderedLogger() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = baseArguments + ["-appIntentURL", starterIntentURL]
        // A prewarmed process can miss this launch's intent URL argument and
        // remain on Home. Require a cold boundary so the configured choice is
        // always delivered to the same production route exercised below.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        acceptanceExpect(
            ["add-set-button", "finish-workout-button"],
            visibleLabels: ["Machine Chest Press"],
            phase: .setup,
            invariants: [
                "A configured Start Workout intent opens the selected saved routine in the normal live logger",
                "The route uses the seeded routine rather than creating an empty workout",
            ]
        )
        app.acceptanceLaunch()

        XCTAssertTrue(
            app.buttons["finish-workout-button"].firstMatch.waitForExistence(timeout: 15),
            "Expected the configured routine to open in the live logger."
        )
        XCTAssertTrue(
            app.staticTexts["Machine Chest Press"].firstMatch.exists,
            "Expected the selected routine's seeded exercise in the live logger."
        )
    }

    @MainActor
    func testAppIntentDurablyStartsTheTrackedRoutine() throws {
        let app = XCUIApplication()
        let fixtureToken = "App Intent verification \(UUID().uuidString.prefix(8))"
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        // Start from the same account boundary as the rest of this suite. The
        // tracked Cindy and named AX400 routines use fixture-owned identities,
        // so resetting starter content cannot invalidate either routine or the
        // workout created from it.
        app.launchArguments = [
            "--reset-store",
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "home",
            "--app-intent-workout-fixture",
            "-appIntentWorkoutFixtureToken", fixtureToken,
            "-appIntentURL", "forgefit://start-next",
        ]
        app.launchEnvironment["FORGEFIT_APP_INTENT_WORKOUT_FIXTURE_TOKEN"] = fixtureToken
        // Xcode can leave the target prewarmed between focused UI-test runs.
        // A prewarmed process never receives this launch's arguments, so make
        // the fixture boundary explicitly cold before recording the user flow.
        app.terminate()
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 5),
            "Expected ForgeFit to be fully stopped before the App Intent fixture launch."
        )
        acceptanceExpect(
            ["expand-active-workout"],
            visibleLabels: ["App Intent Cycle", "Machine Chest Press"],
            phase: .setup,
            invariants: [
                "The modern App Intent route commits the next tracked routine before reporting success",
                "The started session is visibly resumable through the typed navigation boundary",
            ]
        )
        app.acceptanceLaunch()

        let resume = app.buttons["expand-active-workout"].firstMatch
        XCTAssertTrue(
            resume.waitForExistence(timeout: 15),
            "Expected the App-Intent-started tracked routine to be visibly resumable."
        )
        acceptanceExpect(
            phase: .setup,
            invariants: [
                "The production App Intent route durably starts a workout before the app process terminates",
                "Freshness is verified from a new process so a pre-reset SwiftData object cannot satisfy the assertion",
            ]
        )
        app.acceptanceTerminate()

        app.launchArguments = [
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "home",
        ]
        // launchEnvironment survives XCUIApplication relaunches. Remove the
        // fixture trigger so this is a genuinely ordinary cold start; leaving
        // it set would seed again and deliberately clear the active workout we
        // are trying to prove durable.
        app.launchEnvironment.removeValue(
            forKey: "FORGEFIT_APP_INTENT_WORKOUT_FIXTURE_TOKEN"
        )
        acceptanceExpect(
            ["expand-active-workout"],
            visibleLabels: ["Machine Chest Press"],
            phase: .setup,
            invariants: ["A fresh process reloads exactly the App-Intent-started active workout"]
        )
        app.acceptanceLaunch()

        let durableResume = app.buttons["expand-active-workout"].firstMatch
        XCTAssertTrue(
            durableResume.waitForExistence(timeout: 15),
            "Expected a fresh process to reload the App-Intent-started workout."
        )
        assertFreshAppIntentWorkoutSummary(in: app)
        acceptanceExpect(
            ["add-set-button", "finish-workout-button"],
            visibleLabels: ["Machine Chest Press"],
            invariants: ["The visible Resume control opens ForgeFit's normal live logger"]
        )
        durableResume.acceptanceTap()

        XCTAssertTrue(
            app.buttons["finish-workout-button"].firstMatch.waitForExistence(timeout: 10),
            "Expected Resume to open the App-Intent-started routine in the live logger."
        )
        XCTAssertTrue(app.staticTexts["Machine Chest Press"].firstMatch.exists)
        let copiedSetupNote = app.textFields["workout-note-banner"].firstMatch
        XCTAssertTrue(
            copiedSetupNote.waitForExistence(timeout: 5),
            "Expected the App-Intent-started workout to retain this run's copied setup note."
        )
        XCTAssertEqual(
            copiedSetupNote.value as? String,
            fixtureToken,
            "Expected the relaunched logger to belong to this exact App Intent request."
        )
    }

    @MainActor
    func testResolvedAppEntityStartsAX400InsteadOfTheTrackedFallback() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "home",
            "--app-intent-workout-fixture",
            "-appIntentURL",
            "forgefit://start-choice?id=routine%3A00000000-0000-7000-8000-000000000921",
        ]
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))

        acceptanceExpect(
            ["expand-active-workout"],
            visibleLabels: ["Smith Machine Squat"],
            phase: .setup,
            invariants: [
                "The resolved AX400 App Entity starts the named saved routine",
                "It does not substitute Cindy, the next routine in the tracked microcycle",
            ]
        )
        app.acceptanceLaunch()

        let resume = app.buttons["expand-active-workout"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 15))
        acceptanceExpect(
            ["add-set-button", "finish-workout-button"],
            visibleLabels: ["Smith Machine Squat"],
            invariants: [
                "Resume opens AX400's distinct exercise in the normal logger",
                "The named route remains independent from tracked-next selection",
            ]
        )
        resume.acceptanceTap()

        XCTAssertTrue(app.buttons["finish-workout-button"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Smith Machine Squat"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Machine Chest Press"].firstMatch.exists)
    }

    @MainActor
    func testEmptyWorkoutAppIntentStartsAnEmptyWorkout() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "home",
            "--app-intent-workout-fixture",
            "-appIntentURL", "forgefit://start-choice?id=empty",
        ]
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))

        acceptanceExpect(
            ["expand-active-workout"],
            phase: .setup,
            invariants: [
                "An explicit empty-workout request creates a durable ad-hoc workout",
                "It does not substitute a saved or tracked routine",
            ]
        )
        app.acceptanceLaunch()

        let resume = app.buttons["expand-active-workout"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 15))
        acceptanceExpect(
            ["empty-workout-add-exercise", "finish-workout-button"],
            visibleLabels: ["Ready to log", "Add your first exercise to this workout."],
            invariants: ["Resume opens the normal blank logger with its visible add-exercise action"]
        )
        resume.acceptanceTap()

        XCTAssertTrue(
            app.buttons["empty-workout-add-exercise"].firstMatch.waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.staticTexts["Machine Chest Press"].firstMatch.exists)
    }

    @MainActor
    func testModernAppIntentStatusIsVisibleInSettings() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store",
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "profile",
        ]
        acceptanceExpect(
            visibleLabels: ["Settings"],
            phase: .setup,
            invariants: ["Modern App Intent availability is visible without an app-owned permission prompt"]
        )
        app.acceptanceLaunch()

        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "Expected Profile's visible Settings button.")
        acceptanceExpect(
            ["settings-app-intent-workouts-available"],
            visibleLabels: ["Settings", "Control workouts with Siri"],
            phase: .setup,
            invariants: [
                "The standard Settings sheet explains modern App Intent availability",
                "Users see conversational phrases they can say and a local diagnostic surface",
            ]
        )
        settings.acceptanceTap()

        let enabledStatus = app.descendants(matching: .any)["settings-app-intent-workouts-available"].firstMatch
        XCTAssertTrue(enabledStatus.waitForExistence(timeout: 5), "Expected the App Intent workout status row.")
        XCTAssertTrue(enabledStatus.isHittable, "Expected the App Intent status to be visibly on screen.")
        XCTAssertTrue(app.staticTexts["Control workouts with Siri"].firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["Start, log sets, control rest, and finish with session exertion."].firstMatch.exists
        )
    }

    private func assertFreshAppIntentWorkoutSummary(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let summary = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Workout, ")
        ).firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 5),
            "Expected the active-workout summary.",
            file: file,
            line: line
        )

        let fields = summary.label.components(separatedBy: ", ")
        XCTAssertGreaterThanOrEqual(
            fields.count,
            3,
            "Expected title, elapsed time, and exercise in the active-workout summary: \(summary.label)",
            file: file,
            line: line
        )
        guard fields.count >= 3 else { return }

        let elapsedFields = fields[1].split(separator: ":").compactMap { field -> Int? in
            let raw = field.hasSuffix("s") ? field.dropLast() : Substring(field)
            return Int(raw)
        }
        let elapsedSeconds = elapsedFields.reduce(0) { partial, field in
            (partial * 60) + field
        }
        XCTAssertFalse(
            elapsedFields.isEmpty,
            "Expected a parseable elapsed time in: \(summary.label)",
            file: file,
            line: line
        )
        XCTAssertLessThan(
            elapsedSeconds,
            10 * 60,
            "Expected this App Intent request to create a fresh workout, not reuse an older active session: \(summary.label)",
            file: file,
            line: line
        )
        XCTAssertTrue(
            fields.dropFirst(2).joined(separator: ", ").contains("Machine Chest Press"),
            "Expected the tracked routine's exercise in: \(summary.label)",
            file: file,
            line: line
        )
    }

    @MainActor
    func testIntentNeverSilentlyReplacesAnActiveWorkout() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = baseArguments + ["--auto-start-routine"]
        acceptanceExpect(
            phase: .setup,
            invariants: [
                "A live workout is durably established before the external start arrives",
                "Either the live logger or its visible Resume workout control exposes that active session",
            ]
        )
        app.acceptanceLaunch()
        let finishWorkout = app.buttons["finish-workout-button"].firstMatch
        let resumeWorkout = app.buttons["expand-active-workout"].firstMatch
        let loggerIsVisible = finishWorkout.waitForExistence(timeout: 5)
        try acceptanceRequire(
            loggerIsVisible || resumeWorkout.waitForExistence(timeout: 10),
            "Expected a durable active-workout fixture before relaunch."
        )

        // Relaunch without resetting storage: this is the production shape in
        // which an intent arrives while an earlier session is still active.
        acceptanceExpect(
            phase: .setup,
            invariants: ["The active workout remains stored across an ordinary app termination"]
        )
        app.acceptanceTerminate()
        app.launchArguments = [
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "home",
            "-appIntentURL", starterIntentURL,
        ]
        acceptanceExpect(
            visibleLabels: [
                "You have a workout in progress",
                "Discard Current & Start New",
                "Keep Current Workout",
            ],
            phase: .setup,
            invariants: [
                "An intent start cannot discard the active workout without an explicit destructive choice",
            ]
        )
        app.acceptanceLaunch()

        let keepCurrent = app.buttons["Keep Current Workout"].firstMatch
        XCTAssertTrue(keepCurrent.waitForExistence(timeout: 15), "Expected the active-workout safety decision.")
        acceptanceExpect(
            ["add-set-button", "finish-workout-button"],
            invariants: ["Keeping the current workout returns to the original live logger"]
        )
        keepCurrent.acceptanceTap()
    }

    @MainActor
    func testStartNextExplainsWhenAChoiceIsRequired() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = baseArguments + ["-appIntentURL", "forgefit://start-next"]
        acceptanceExpect(
            ["tab-workout"],
            visibleLabels: [
                "Choose a workout",
                "Choose a workout because no microcycle is being tracked.",
                "OK",
            ],
            phase: .setup,
            invariants: [
                "Start My Next Workout fails closed instead of guessing when no tracked microcycle exists",
                "The user is taken to the visible Workout surface",
            ]
        )
        app.acceptanceLaunch()

        let acknowledge = app.buttons["OK"].firstMatch
        XCTAssertTrue(acknowledge.waitForExistence(timeout: 15), "Expected an explicit choose-workout explanation.")
        acceptanceExpect(
            ["tab-workout", "new-routine-button"],
            visibleLabels: ["Workout"],
            invariants: ["Dismissing the explanation leaves the user at a visible workout chooser"]
        )
        acknowledge.acceptanceTap()
    }

    private var baseArguments: [String] {
        [
            "--reset-store",
            "--skip-onboarding",
            "-didOnboard", "YES",
            "-initialTab", "home",
        ]
    }
}
