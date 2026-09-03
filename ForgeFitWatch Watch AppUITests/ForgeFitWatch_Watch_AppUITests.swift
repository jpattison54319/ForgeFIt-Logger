//
//  ForgeFitWatch_Watch_AppUITests.swift
//  ForgeFitWatch Watch AppUITests
//
//  Created by James Pattison on 6/29/26.
//

import Foundation
import XCTest

private struct WatchAcceptanceScenario: Codable {
    let id: String
    let title: String
    let purpose: String
    let fixtureArguments: [String]
    let checkpoints: [WatchAcceptanceCheckpoint]
}

private struct WatchAcceptanceCheckpoint: Codable {
    let id: String
    let title: String
    let action: String
    let expectedVisibleIdentifiers: [String]
    let expectedVisibleLabels: [String]
    let screenshotRequired: Bool
    let phase: String = "assertion"
    let invariants: [String] = []
}

final class ForgeFitWatch_Watch_AppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testWatchHomeDemo() throws {
        let scenario = WatchAcceptanceScenario(
            id: "watch-home-demo",
            title: "Watch home demo",
            purpose: "Verify the Watch home surface renders an empty-workout path and a synced routine from deterministic state.",
            fixtureArguments: ["--seed-watch-demo"],
            checkpoints: [
                WatchAcceptanceCheckpoint(
                    id: "watch-routines",
                    title: "Synced routines are visible",
                    action: "Launch the Watch from a seeded state, then scroll to the routine list.",
                    expectedVisibleIdentifiers: ["watch-home", "watch-routine-Push Day"],
                    expectedVisibleLabels: ["Push Day"],
                    screenshotRequired: true
                )
            ]
        )
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(
            app,
            scenarioID: "ForgeFitWatch_Watch_AppUITests/testWatchHomeDemo"
        )
        app.launchArguments = scenario.fixtureArguments
        watchAcceptanceExpect(
            ["watch-home", "watch-empty-workout"],
            visibleLabels: ["Empty Workout"]
        )
        app.watchAcceptanceLaunch()

        XCTAssertTrue(
            app.descendants(matching: .any)["watch-home"].firstMatch.waitForExistence(timeout: 15),
            "The seeded Watch home must render"
        )
        XCTAssertTrue(
            app.buttons["watch-empty-workout"].firstMatch.exists,
            "The Watch must expose the visible Empty Workout action"
        )
        watchAcceptanceExpect(
            ["watch-home", "watch-routine-Push Day"],
            visibleLabels: ["Push Day"]
        )
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(
            app.buttons["watch-routine-Push Day"].firstMatch.waitForExistence(timeout: 10),
            "The Watch must render the synced Push Day routine"
        )
    }

    @MainActor
    func testWatchActiveWorkoutDemo() throws {
        let scenario = WatchAcceptanceScenario(
            id: "watch-active-workout-demo",
            title: "Watch active workout demo",
            purpose: "Verify the Watch active workout, set completion, controls, and destructive discard confirmation from deterministic state.",
            fixtureArguments: ["--seed-watch-demo", "--seed-watch-demo-active"],
            checkpoints: [
                WatchAcceptanceCheckpoint(
                    id: "watch-active-exercises",
                    title: "Active exercises are visible",
                    action: "Launch the Watch with a seeded active workout.",
                    expectedVisibleIdentifiers: ["watch-active-workout", "watch-exercises-page", "watch-exercise-Barbell Bench Press"],
                    expectedVisibleLabels: [],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-set-list",
                    title: "Exercise set list is visible",
                    action: "Open the seeded exercise and complete the third set from the visible set list.",
                    expectedVisibleIdentifiers: ["watch-set-list", "watch-toggle-set-3"],
                    expectedVisibleLabels: [],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-controls",
                    title: "Workout controls are visible",
                    action: "Return to the exercise page and navigate to the visible controls page.",
                    expectedVisibleIdentifiers: ["watch-controls-page"],
                    expectedVisibleLabels: ["Discard"],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-discard-confirmation",
                    title: "Discard is confirmable",
                    action: "Open Discard and inspect the warning before closing it.",
                    expectedVisibleIdentifiers: ["watch-controls-page"],
                    expectedVisibleLabels: ["Discard workout?", "All logged sets from this session will be lost."],
                    screenshotRequired: true
                )
            ]
        )
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(
            app,
            scenarioID: "ForgeFitWatch_Watch_AppUITests/testWatchActiveWorkoutDemo"
        )
        app.launchArguments = scenario.fixtureArguments
        watchAcceptanceExpect(
            ["watch-active-workout", "watch-exercises-page", "watch-exercise-Barbell Bench Press"]
        )
        app.watchAcceptanceLaunch()

        XCTAssertTrue(
            app.descendants(matching: .any)["watch-active-workout"].firstMatch.waitForExistence(timeout: 15),
            "The seeded active Watch workout must render"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercises-page"].firstMatch.exists,
            "The Watch must begin on the exercise/set page"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists,
            "The Watch must render the seeded exercise"
        )

        let exercise = app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch
        XCTAssertTrue(exercise.isHittable, "The seeded exercise must be interactable")
        watchAcceptanceExpect(["watch-set-list", "watch-toggle-set-3"])
        exercise.watchAcceptanceTap()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-set-list"].firstMatch.waitForExistence(timeout: 10),
            "Opening an exercise must show its set list"
        )

        let thirdSet = app.descendants(matching: .any)["watch-toggle-set-3"].firstMatch
        XCTAssertTrue(thirdSet.waitForExistence(timeout: 10), "The third set must be directly completable")
        XCTAssertTrue(thirdSet.isHittable, "The third set control must be hittable")
        watchAcceptanceExpect(["watch-set-list", "watch-toggle-set-3"])
        thirdSet.watchAcceptanceTap()

        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "The set list must provide visible back navigation")
        watchAcceptanceExpect(["watch-exercises-page"])
        back.watchAcceptanceTap()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercises-page"].firstMatch.waitForExistence(timeout: 10),
            "Returning from set details must restore the exercise page"
        )

        let pageStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.52))
        let pageEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.12))
        watchAcceptanceExpect(["watch-exercises-page"])
        pageStart.watchAcceptancePress(forDuration: 0.1, thenDragTo: pageEnd)
        watchAcceptanceExpect(["watch-controls-page"], visibleLabels: ["Discard"])
        app.watchAcceptanceSwipeUp()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-controls-page"].firstMatch.waitForExistence(timeout: 10),
            "The active workout must expose controls as a visible page"
        )

        let discard = app.buttons["Discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 10), "Discard must be visible in the controls page")
        watchAcceptanceExpect(
            ["watch-controls-page"],
            visibleLabels: ["Discard workout?", "All logged sets from this session will be lost."]
        )
        discard.watchAcceptanceTap()
        XCTAssertTrue(app.staticTexts["Discard workout?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["All logged sets from this session will be lost."].exists)
        let cancel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Close", "Cancel", "Dismiss"]))
            .firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), "The discard dialog must provide a visible close action")
        watchAcceptanceExpect(["watch-controls-page"], visibleLabels: ["Discard"])
        cancel.watchAcceptanceTap()
    }

    /// Reproduces a queued prior-session completion coexisting with a newly
    /// active phone-start snapshot. The new workout must own the screen without
    /// asking the athlete to dismiss the old Done summary.
    @MainActor
    func testPhoneStartedWorkoutSupersedesPriorSummary() throws {
        let scenario = WatchAcceptanceScenario(
            id: "watch-phone-start-supersedes-summary",
            title: "Phone start supersedes prior Watch summary",
            purpose: "Verify a newly active phone-started workout is shown instead of a retained completion summary.",
            fixtureArguments: [
                "--seed-watch-demo",
                "--seed-watch-demo-active",
                "--seed-watch-superseded-summary",
            ],
            checkpoints: [
                WatchAcceptanceCheckpoint(
                    id: "watch-new-workout-active",
                    title: "The new workout owns the Watch screen",
                    action: "Launch with a prior summary and a newer active workout.",
                    expectedVisibleIdentifiers: [
                        "watch-active-workout",
                        "watch-exercises-page",
                        "watch-exercise-Barbell Bench Press",
                    ],
                    expectedVisibleLabels: [],
                    screenshotRequired: true
                )
            ]
        )
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(
            app,
            scenarioID: "ForgeFitWatch_Watch_AppUITests/testPhoneStartedWorkoutSupersedesPriorSummary"
        )
        app.launchArguments = scenario.fixtureArguments
        watchAcceptanceExpect(
            [
                "watch-active-workout",
                "watch-exercises-page",
                "watch-exercise-Barbell Bench Press",
            ]
        )
        app.watchAcceptanceLaunch()

        XCTAssertTrue(
            app.descendants(matching: .any)["watch-active-workout"].firstMatch.waitForExistence(timeout: 15),
            "A new phone-started workout must replace a prior completion summary"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-exercise-Barbell Bench Press"].firstMatch.exists,
            "The new workout's live exercise list must remain visible"
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["watch-summary"].firstMatch.exists,
            "The prior workout's Done screen must not cover the active workout"
        )
    }

    /// The wrist half of the extended set type: the row states the partials
    /// that followed the full-range reps, and the editor can change them.
    @MainActor
    func testWatchExtendedSetShowsAndEditsItsPartials() throws {
        let scenario = WatchAcceptanceScenario(
            id: "watch-lengthened-extended-set",
            title: "Watch extended set partials",
            purpose: "Verify the Watch renders an extended set's trailing partials and can edit them from the wrist.",
            fixtureArguments: ["--seed-watch-demo", "--seed-watch-demo-active", "--seed-watch-lengthened"],
            checkpoints: [
                WatchAcceptanceCheckpoint(
                    id: "watch-extended-set-row",
                    title: "The extended set states its partials",
                    action: "Open the seeded exercise carrying an extended set.",
                    expectedVisibleIdentifiers: ["watch-set-list", "watch-toggle-set-3E"],
                    expectedVisibleLabels: [],
                    screenshotRequired: true
                ),
                WatchAcceptanceCheckpoint(
                    id: "watch-extended-set-editor",
                    title: "The editor offers a partials value",
                    action: "Open the set editor from the row's edit control.",
                    expectedVisibleIdentifiers: [],
                    expectedVisibleLabels: ["partials"],
                    screenshotRequired: true
                )
            ]
        )
        let app = XCUIApplication()
        WatchHumanActionRecorder.shared.register(
            app,
            scenarioID: "ForgeFitWatch_Watch_AppUITests/testWatchExtendedSetShowsAndEditsItsPartials"
        )
        app.launchArguments = scenario.fixtureArguments
        watchAcceptanceExpect(["watch-active-workout"])
        app.watchAcceptanceLaunch()

        XCTAssertTrue(
            app.descendants(matching: .any)["watch-active-workout"].firstMatch.waitForExistence(timeout: 15),
            "The seeded active Watch workout must render"
        )

        let exercise = app.descendants(matching: .any)["watch-exercise-Incline Dumbbell Press"].firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 10), "The seeded exercise must be reachable")
        if !exercise.isHittable { app.watchAcceptanceSwipeUp() }
        watchAcceptanceExpect(["watch-set-list", "watch-toggle-set-3E"])
        exercise.watchAcceptanceTap()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch-set-list"].firstMatch.waitForExistence(timeout: 10),
            "Opening an exercise must show its set list"
        )

        let extendedRow = app.descendants(matching: .any)["watch-toggle-set-3E"].firstMatch
        XCTAssertTrue(extendedRow.waitForExistence(timeout: 10), "The extended set must appear in the wrist set list")
        XCTAssertTrue(
            extendedRow.label.contains("+4 partials"),
            "The wrist row must state the partials that followed; saw \(extendedRow.label)."
        )

        let edit = app.descendants(matching: .any)["watch-edit-set-3E"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "The row must expose a visible edit control")
        watchAcceptanceExpect(visibleLabels: ["partials"])
        edit.watchAcceptanceTap()
        XCTAssertTrue(
            app.staticTexts["partials"].waitForExistence(timeout: 10),
            "The wrist editor must offer the partials value on an extended set"
        )
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().watchAcceptanceLaunch()
        }
    }
}
