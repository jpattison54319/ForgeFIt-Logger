import XCTest

final class WorkoutLoggingChangesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testTimedStrengthManuallyFinishesPausesAndAutoCompletes() throws {
        let app = try openExercisePicker(seedsBodyweight: true)
        let search = app.searchFields.firstMatch
        try tap(search, labels: ["Search"])
        acceptanceExpect(["create-from-search"], invariants: ["Search the catalog before creating a wall sit."])
        search.acceptanceTypeText("Test Wall Sit")
        try tap(element(app, "create-from-search"), showing: ["exercise-modality", "create-exercise-name"])
        let timed = app.buttons.matching(NSPredicate(format: "label IN %@", ["Timed strength", "Timed"])).firstMatch
        try tap(timed, showing: ["exercise-hold-duration"])

        try tap(app.buttons["Create"], showing: ["timed-set-duration", "start-hold", "finish-timed-set"])
        acceptanceAssert(!app.textFields["Reps"].exists, "A hold does not need a reps field.")
        assertTimedGridRow(
            completion: element(app, "finish-timed-set"),
            time: element(app, "timed-set-duration"),
            playback: element(app, "start-hold")
        )

        try setDuration(minutes: 1, seconds: 5, in: app)
        let duration = element(app, "timed-set-duration")
        acceptanceAssert(duration.value as? String == "1:05", "Minutes and seconds must both remain visible.")
        try tap(element(app, "finish-timed-set"), showing: ["timed-set-completed", "reopen-timed-set"])
        let volume = app.staticTexts["172 lbs"].firstMatch
        acceptanceAssert(volume.waitForExistence(timeout: 5), "The finished bodyweight set should add 172 lbs to volume.")
        acceptanceAssert(duration.value as? String == "1:05", "Manual finish should log the entered time.")

        try tap(element(app, "reopen-timed-set"), showing: ["start-hold"])
        try tap(element(app, "start-hold"), showing: ["pause-hold", "hold-running"])
        try tap(element(app, "pause-hold"), showing: ["resume-hold", "hold-paused", "finish-timed-set"])
        let paused = element(app, "hold-paused")
        assertTimedGridRow(
            completion: element(app, "finish-timed-set"), time: paused,
            playback: element(app, "resume-hold")
        )
        let held = paused.value as? String
        RunLoop.current.run(until: Date().addingTimeInterval(1.3))
        acceptanceAssert(paused.value as? String == held, "Time spent paused should not add to the recorded hold.")
        try tap(element(app, "finish-timed-set"), showing: ["timed-set-completed", "timed-set-duration"])
        let actual = try XCTUnwrap(duration.value as? String)
        acceptanceAssert(actual == held && actual != "1:05" && actual != "0s", "The partial set should log the time shown when paused, got \(actual).")

        try tap(element(app, "reopen-timed-set"), showing: ["start-hold"])
        try setDuration(minutes: 0, seconds: 14, in: app)
        try tap(element(app, "start-hold"), showing: ["hold-running"])
        acceptanceAssert(
            element(app, "timed-set-completed").waitForExistence(timeout: 25),
            "The countdown should complete the set on its own."
        )
        acceptanceAssert(duration.value as? String == "14s", "Automatic completion should log the full target.")
        let addSet = element(app, "add-set-button")
        try tap(addSet, showing: ["timed-set-completed", "timed-set-pending", "start-hold"])
        try tap(addSet, showing: ["timed-set-pending", "start-hold"])
        acceptanceExpect(["timed-set-pending", "start-hold", "finish-timed-set"],
                         invariants: ["Repeated timed sets stay compact and individually readable."])
        app.acceptanceSwipeUp()
        let pending = app.descendants(matching: .any).matching(identifier: "timed-set-pending")
        acceptanceAssert(pending.count == 2, "One logged hold and two fresh sets should coexist.")
        let startButtons = app.buttons.matching(identifier: "start-hold")
        let finishButtons = app.buttons.matching(identifier: "finish-timed-set")
        acceptanceAssert(startButtons.count == 2 && finishButtons.count == 2, "Each pending set needs its own actions.")
        let durations = app.buttons.matching(identifier: "timed-set-duration")
        acceptanceAssert(durations.count == 3, "All three sets should show their own time.")
        for index in 0..<2 {
            assertTimedGridRow(
                completion: finishButtons.element(boundBy: index),
                time: durations.element(boundBy: index + 1),
                playback: startButtons.element(boundBy: index)
            )
        }
        acceptanceAssert(
            startButtons.element(boundBy: 0).frame.maxY < startButtons.element(boundBy: 1).frame.minY,
            "The two sets must have separate touch targets."
        )
        let rightEdge = durations.firstMatch.frame.maxX
        for index in 1..<3 {
            acceptanceAssert(abs(durations.element(boundBy: index).frame.maxX - rightEdge) <= 1,
                             "Completed and pending durations should align.")
        }
        try setDuration(minutes: 59, seconds: 59, row: 2, in: app)
        acceptanceAssert(durations.element(boundBy: 1).value as? String == "14s", "Changing one target should leave the other intact.")
        let longestDuration = durations.element(boundBy: 2)
        acceptanceAssert(longestDuration.value as? String == "59:59", "The longest target should display both minute and second digits.")
        assertTimedGridRow(
            completion: finishButtons.element(boundBy: 1),
            time: longestDuration,
            playback: startButtons.element(boundBy: 1)
        )
        try tap(startButtons.element(boundBy: 1), showing: ["hold-running", "pause-hold", "timed-set-pending"])
        acceptanceAssert(!startButtons.firstMatch.isEnabled, "Only one set can count down at a time.")
        let viewport = app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "active-workout-theme-")).firstMatch
        acceptanceAssert(viewport.exists && volume.exists && viewport.frame.minY >= volume.frame.maxY,
                         "The exercise list should scroll below the workout stats during the countdown.")
        try tap(element(app, "pause-hold"), showing: ["resume-hold", "hold-paused"])

        try tap(element(app, "add-to-workout"), showing: ["create-exercise-button"])
        try pickExercise("Bodyweight Squat", search: "Bodyweight Squat", in: app)
        let repCheck = element(app, "complete-set-1")
        try acceptanceRequire(repCheck.waitForExistence(timeout: 10), "The rep exercise should show its completion control.")
        let timedCheck = element(app, "reopen-timed-set")
        acceptanceAssert(
            abs(repCheck.frame.minX - timedCheck.frame.minX) <= 1
                && abs(repCheck.frame.width - timedCheck.frame.width) <= 1,
            "Rep and timed sets should use the same completion column."
        )
    }

    @MainActor
    func testRoutineTimedTargetsUseOneRowPerSet() throws {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = ["--reset-store", "--skip-onboarding", "-didOnboard", "YES", "-initialTab", "workout"]
        acceptanceExpect(["new-routine-button"], phase: .setup)
        app.acceptanceLaunch()
        try tap(element(app, "new-routine-button"), showing: ["add-to-routine"])
        try tap(element(app, "add-to-routine"), showing: ["create-exercise-button"])
        try pickExercise("Plank", search: "Plank", in: app)
        try tap(element(app, "routine-add-set"), showing: ["routine-set-duration"], labels: ["TIME"])
        try setDuration(minutes: 1, seconds: 10, row: 1, identifier: "routine-set-duration", in: app)

        let durations = app.buttons.matching(identifier: "routine-set-duration")
        let setNumbers = app.buttons.matching(identifier: "timed-routine-set-options")
        acceptanceAssert(durations.count == 2 && setNumbers.count == 2, "The plan needs two distinct timed targets.")
        acceptanceAssert(durations.firstMatch.value as? String == "30s", "Set 1 keeps its default duration.")
        acceptanceAssert(durations.element(boundBy: 1).value as? String == "1:10", "Set 2 keeps its edited duration.")
        for index in 0..<2 {
            acceptanceAssert(
                abs(durations.element(boundBy: index).frame.midY - setNumbers.element(boundBy: index).frame.midY) <= 1,
                "The target and set number should share the usual editor row."
            )
        }
    }

    @MainActor
    func testChangeMonsterWalkFromRepsToDistanceAndSwitchUnits() throws {
        let app = try openExercisePicker()
        try pickExercise("Monster Walk", search: "Monster Walk", in: app)
        acceptanceAssert(app.textFields["Reps"].exists, "The existing exercise starts as rep-based.")
        try tap(app.buttons["Monster Walk"].firstMatch, labels: ["Edit exercise"])
        try tap(app.buttons["Edit exercise"].firstMatch, showing: ["exercise-modality"])
        try tap(app.buttons["Distance"].firstMatch, showing: ["exercise-modality"])
        try tap(app.buttons["Save"].firstMatch, showing: ["exercise-detail-back"])
        try tap(element(app, "exercise-detail-back"), showing: [
            "strength-distance-value", "strength-distance-unit", "resistance-band-color"
        ])
        acceptanceAssert(!app.textFields["Reps"].exists, "The pending row now tracks distance.")
        let field = element(app, "strength-distance-value")
        let unit = element(app, "strength-distance-unit")
        if unit.value as? String != "Meters" {
            try tap(unit, labels: ["Meters", "Feet"])
            try tap(app.buttons["Meters"].firstMatch, showing: ["strength-distance-unit"])
        }
        let color = element(app, "resistance-band-color")
        try tap(color, labels: ["Blue · 100 lbs"])
        try tap(app.buttons["Blue · 100 lbs"], showing: ["resistance-band-color", "strength-distance-value"])
        let load = element(app, "strength-set-load")
        acceptanceAssert(load.value as? String == "100", "Band selection should retain its 100 lb load.")
        acceptanceAssert(color.frame.maxX + 4 <= load.frame.minX, "Keep the band control clear of the load.")
        try tap(field, showing: ["strength-distance-value", "strength-distance-unit"])
        acceptanceExpect(["strength-distance-value"], invariants: ["Enter 30 meters for the strength set."])
        field.acceptanceTypeText("30")
        try tap(unit, labels: ["Meters", "Feet"])
        try tap(app.buttons["Feet"].firstMatch, showing: ["strength-distance-unit", "strength-distance-value"])
        acceptanceAssert(unit.value as? String == "Feet", "The row should display feet.")
        acceptanceAssert(field.value as? String == "98.43", "30 meters should display as 98.43 feet.")
        try tap(element(app, "complete-distance-set"), showing: ["reopen-distance-set", "resistance-band-color"], labels: ["100 lbs"])
        try tap(unit, labels: ["Meters", "Feet"])
        try tap(app.buttons["Meters"].firstMatch, showing: ["strength-distance-unit", "reopen-distance-set"])
        acceptanceAssert(field.value as? String == "30", "Switching back should reveal the exact original distance.")
    }

    @MainActor
    func testBandColorAndLoadHaveSeparateTouchAreas() throws {
        let app = try openExercisePicker()
        try pickExercise("Band Good Morning", search: "Band Good Morning", in: app)
        let color = element(app, "resistance-band-color")
        let weight = app.textFields["Weight"].firstMatch
        try tap(color, labels: ["Blue · 100 lbs"])
        try tap(app.buttons["Blue · 100 lbs"].firstMatch, showing: ["resistance-band-color"])
        acceptanceAssert(weight.value as? String == "100", "Selecting Blue should enter its 100 lb load.")
        acceptanceAssert(color.frame.maxX + 4 <= weight.frame.minX, "Band picker and load need a visible gap.")
    }

    @MainActor
    func testLiveRunCanSwitchZoneTwoOffWithoutStopping() throws {
        let app = try openExercisePicker()
        try pickExercise("Running, Treadmill", search: "Running, Treadmill", in: app)
        try tap(element(app, "start-cardio-segment"), showing: ["live-zone-lock-menu"], labels: ["Recording"])
        let zone = element(app, "live-zone-lock-menu")
        try tap(zone, labels: ["Z2 · Endurance", "Off"])
        try tap(app.buttons["Z2 · Endurance"], showing: ["live-zone-lock-status"], labels: ["Z2 · Endurance", "Recording"])
        acceptanceAssert(zone.value as? String == "Z2 · Endurance", "Zone 2 should be active.")
        try tap(zone, labels: ["Off"])
        try tap(app.buttons["Off"], showing: ["live-zone-lock-status"], labels: ["Off", "Recording"])
        acceptanceAssert(zone.value as? String == "Off", "The live goal should be off while the run keeps recording.")
    }

    @MainActor
    private func openExercisePicker(seedsBodyweight: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = [
            "--reset-store", "--skip-onboarding", "-didOnboard", "YES", "-initialTab", "home",
            "-weightUnitRaw", "lb", "-liveSyncEnabled", "NO"
        ]
        if seedsBodyweight { app.launchEnvironment["FORGEFIT_SEED_WORKOUT_BODYWEIGHT"] = "1" }
        acceptanceExpect(["start-empty-workout"], phase: .setup)
        app.acceptanceLaunch()
        let start = element(app, "start-empty-workout")
        try acceptanceRequire(start.waitForExistence(timeout: 15), "Home should offer an empty workout.")
        acceptanceExpect(phase: .transition, invariants: ["Start an empty workout from Home."])
        start.acceptanceTap()
        let replace = app.buttons["Discard Current & Start New"]
        if replace.exists {
            try tap(replace, showing: ["empty-workout-add-exercise"])
        }
        try tap(element(app, "empty-workout-add-exercise"), showing: ["create-exercise-button"])
        return app
    }

    @MainActor
    private func assertTimedGridRow(completion: XCUIElement, time: XCUIElement, playback: XCUIElement) {
        let check = completion.frame, duration = time.frame, timer = playback.frame
        acceptanceAssert(abs(check.midY - timer.midY) <= 1 && abs(check.midY - duration.midY) <= 1,
                         "The check, duration, and timer should fit on one line.")
        // XCTest can return fractional screen coordinates for a 44-point view.
        acceptanceAssert(check.width >= 43.5 && check.height >= 43.5 && timer.width >= 43.5 && timer.height >= 43.5
                         && duration.minX > check.maxX && timer.minX >= duration.maxX + 4,
                         "Expected the standard check column and a distinct timer button, got \(check), \(duration), and \(timer).")
    }

    @MainActor
    private func pickExercise(_ name: String, search: String, in app: XCUIApplication) throws {
        let searchField = app.searchFields.firstMatch
        try tap(searchField, labels: ["Search"])
        let id = "exercise-row-\(name)"
        acceptanceExpect([id])
        searchField.acceptanceTypeText(search)
        try tap(element(app, id), labels: ["Add 1 exercise"])
        try tap(app.buttons["Add 1 exercise"], labels: [name])
    }

    @MainActor
    private func setDuration(
        minutes: Int, seconds: Int, row: Int = 0, identifier: String = "timed-set-duration", in app: XCUIApplication
    ) throws {
        let duration = app.buttons.matching(identifier: identifier).element(boundBy: row)
        try tap(duration, showing: ["save-hold-duration"], labels: ["Minutes", "Seconds"])
        let wheels = app.pickerWheels
        try acceptanceRequire(wheels.count == 2, "Expected minute and second wheels.")
        adjust(wheels.element(boundBy: 0), to: minutes)
        adjust(wheels.element(boundBy: 1), to: seconds)
        try tap(element(app, "save-hold-duration"), showing: [identifier])
    }

    @MainActor
    private func adjust(
        _ wheel: XCUIElement, to value: Int,
        file: StaticString = #fileID, line: UInt = #line
    ) {
        let text = String(value)
        acceptanceExpect(["save-hold-duration"], invariants: ["The duration picker keeps both units editable."])
        AcceptanceHumanActionRecorder.shared.perform(
            action: "adjustPickerWheel", target: wheel, sourceFile: file, sourceLine: line
        ) {
            wheel.adjust(toPickerWheelValue: text)
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func tap(
        _ element: XCUIElement, showing identifiers: [String] = [], labels: [String] = [],
        file: StaticString = #fileID, line: UInt = #line
    ) throws {
        try acceptanceRequire(element.waitForExistence(timeout: 15), "Expected \(element) before tapping.", file: file, line: line)
        acceptanceExpect(identifiers, visibleLabels: labels)
        element.acceptanceTap(file: file, line: line)
    }
}
