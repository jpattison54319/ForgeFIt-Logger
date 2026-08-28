import XCTest

/// UI coverage for the routine editor's screen-owned pending-draft contract.
/// Invalid percentage text is intentionally local: it must remain visible for
/// correction, block every terminal save, and never replace the last valid
/// SwiftData value at a scene-lifecycle boundary.
final class RoutineLoadPrescriptionDraftUITests: XCTestCase {
    private let persistedArguments = [
        "--skip-onboarding",
        "--suppress-health-refresh",
        "-didOnboard", "YES",
        "-weightUnitRaw", "kg",
        "-initialTab", "workout",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testMalformedPercentageSurvivesBlurAndBlocksSave() throws {
        let scenario = AcceptanceScenarioCatalog.routineMalformedPercentageSaveGuard
        let app = try launchEditor(scenario: scenario)
        defer { app.terminate() }

        let field = try selectPercentageField(in: app)
        // Keep a valid model value underneath the malformed screen-owned
        // draft. This also leaves the estimate-workout action visible so the
        // same validation boundary can be exercised below.
        enter("70", in: field, invalid: false)
        try blurField(in: app)
        enter("67--72", in: field, invalid: true)
        try blurField(in: app, checkpoint: scenario.checkpoints[2])

        acceptanceAssert(field.value as? String == "67--72", "Blur must preserve malformed text exactly.")
        acceptanceAssert(
            invalidReceipt(in: app).waitForExistence(timeout: 5),
            "Blur must leave an accessible invalid-state receipt beside the malformed draft."
        )

        acceptanceExpect(
            scenario.checkpoints[3].expectedVisibleIdentifiers,
            visibleLabels: scenario.checkpoints[3].expectedVisibleLabels,
            phase: scenario.checkpoints[3].phase,
            invariants: scenario.checkpoints[3].invariants
        )
        app.buttons["routine-editor-save-button"].firstMatch.acceptanceTap()
        let alert = app.alerts["Check Routine Values"].firstMatch
        acceptanceAssert(alert.waitForExistence(timeout: 5), "Save must explain why the routine cannot close.")
        acceptanceAssert(
            app.buttons["routine-editor-save-button"].firstMatch.exists,
            "A rejected Save must leave the routine editor mounted."
        )

        acceptanceExpect(
            scenario.checkpoints[2].expectedVisibleIdentifiers,
            visibleLabels: scenario.checkpoints[2].expectedVisibleLabels,
            phase: scenario.checkpoints[2].phase,
            invariants: scenario.checkpoints[2].invariants
        )
        app.buttons["OK"].firstMatch.acceptanceTap()
        acceptanceAssert(waitUntil {
            app.buttons["routine-editor-save-button"].firstMatch.isHittable
        }, "Dismissing the explanation must return to the editable routine.")
        acceptanceAssert(field.value as? String == "67--72", "The explanation must not replace malformed text.")
        acceptanceAssert(invalidReceipt(in: app).exists, "The invalid-state receipt must remain visible after dismissing the alert.")

        let createEstimate = app.buttons["create-1rm-estimate"].firstMatch
        for _ in 0..<5 where !(createEstimate.exists && createEstimate.isHittable) {
            app.acceptanceSwipeDown(velocity: .fast)
        }
        try acceptanceRequire(
            waitUntil { createEstimate.exists && createEstimate.isHittable },
            "The valid underlying percentage should keep Create Estimate available."
        )
        acceptanceExpect(
            ["routine-set-load-invalid", "routine-editor-save-button"],
            invariants: ["Starting an estimate cannot bypass the malformed routine draft."]
        )
        createEstimate.acceptanceTap()
        acceptanceAssert(
            app.alerts["Check Routine Values"].firstMatch.waitForExistence(timeout: 5),
            "Create Estimate must use the same invalid-draft guard as Save and Back."
        )
        acceptanceAssert(
            !app.buttons["finish-workout-button"].firstMatch.exists,
            "A rejected estimate start must not create or present a workout."
        )
    }

    @MainActor
    func testMalformedPercentageSurvivesBackgroundButDoesNotPersist() throws {
        let scenario = AcceptanceScenarioCatalog.routineMalformedPercentageLifecycle
        let app = try launchEditor(scenario: scenario)
        defer { app.terminate() }

        var field = try selectPercentageField(in: app)

        // Establish and durably save the last valid model value first. The
        // malformed draft entered afterward must never overwrite this value.
        enter("70", in: field, invalid: false)
        try blurField(in: app)
        acceptanceAssert(field.value as? String == "70", "The valid percentage must remain visible after blur.")
        settle(for: 2.25)

        enter("67--72", in: field, invalid: true)
        acceptanceExpect(
            phase: .transition,
            invariants: ["The app leaves the foreground while the malformed editor draft remains screen-owned."]
        )
        XCUIDevice.shared.acceptancePress(.home)
        let backgrounded = app.wait(for: .runningBackground, timeout: 3)
            || app.wait(for: .runningBackgroundSuspended, timeout: 3)
        try acceptanceRequire(backgrounded, "The app must cross a real scene background boundary.")

        expect(scenario.checkpoints[2])
        app.acceptanceActivate()
        try acceptanceRequire(app.wait(for: .runningForeground, timeout: 8), "The app did not return to the foreground.")
        dismissInvalidAlertIfPresented(in: app, checkpoint: scenario.checkpoints[2])

        acceptanceAssert(
            app.buttons["routine-editor-save-button"].firstMatch.waitForExistence(timeout: 8),
            "Foregrounding must restore the still-live editor."
        )
        acceptanceAssert(
            field.value as? String == "67--72",
            "A lifecycle flush must not replace malformed local text with the model value."
        )
        acceptanceAssert(
            invalidReceipt(in: app).waitForExistence(timeout: 5),
            "The invalid-state receipt must survive the foreground transition."
        )

        // Reopen from the persisted store without resetting or reseeding. The
        // local malformed draft disappears with the editor, while the last
        // valid authored percentage remains exactly 70.
        acceptanceExpect(
            phase: .transition,
            invariants: ["Terminating discards only the editor-owned malformed draft, not the last valid persisted value."]
        )
        app.acceptanceTerminate()
        app.launchArguments = persistedArguments
        expect(scenario.checkpoints[0])
        app.acceptanceLaunch()
        try openLongRoutineEditor(in: app, checkpoint: scenario.checkpoints[1])
        field = try existingPercentageField(in: app)

        expect(
            scenario.checkpoints[3],
            oracles: [
                AcceptanceOracle(id: "last-valid-percentage-is-70") {
                    let isValid = field.value as? String == "70" && !self.invalidReceipt(in: app).exists
                    return AcceptanceOracleResult(
                        id: "last-valid-percentage-is-70",
                        outcome: isValid ? .pass : .fail,
                        message: isValid
                            ? "The last valid percentage survived relaunch."
                            : "Expected 70 with no invalid-state receipt after relaunch."
                    )
                }
            ]
        )
        field.acceptanceTap()

        acceptanceAssert(
            field.value as? String == "70",
            "Backgrounding must not persist a malformed percentage over the last valid value."
        )
        acceptanceAssert(!invalidReceipt(in: app).exists, "A valid persisted percentage must not display an invalid-state receipt.")
    }

    // MARK: - Deterministic fixture navigation

    @MainActor
    private func launchEditor(scenario: AcceptanceScenario) throws -> XCUIApplication {
        let app = XCUIApplication()
        AcceptanceHumanActionRecorder.shared.register(app, testName: name, sourceFile: #fileID)
        app.launchArguments = scenario.fixtureArguments
        expect(scenario.checkpoints[0])
        app.acceptanceLaunch()
        try openLongRoutineEditor(in: app, checkpoint: scenario.checkpoints[1])
        return app
    }

    @MainActor
    private func openLongRoutineEditor(
        in app: XCUIApplication,
        checkpoint: AcceptanceCheckpoint
    ) throws {
        let menu = app.buttons["routine-menu-Long Routine"].firstMatch
        try acceptanceRequire(menu.waitForExistence(timeout: 45), "Expected the deterministic Long Routine fixture.")
        try tapWhenReady(
            menu,
            expectedLabels: ["Edit Long Routine"],
            invariant: "The visible routine menu exposes its edit action."
        )

        let edit = app.buttons["Edit Long Routine"].firstMatch
        try acceptanceRequire(edit.waitForExistence(timeout: 5), "Expected the visible Edit Long Routine action.")
        try tapWhenReady(edit, checkpoint: checkpoint)
        try acceptanceRequire(
            app.scrollViews["routine-editor-scroll"].firstMatch.waitForExistence(timeout: 10),
            "Expected Long Routine to open in the routine editor."
        )
    }

    @MainActor
    private func selectPercentageField(in app: XCUIApplication) throws -> XCUIElement {
        let basis = try revealLoadBasis(in: app)
        try tapWhenReady(
            basis,
            expectedLabels: ["% estimated 1RM"],
            invariant: "The load-basis menu presents percentage mode."
        )

        let percentage = app.buttons["% estimated 1RM"].firstMatch
        try acceptanceRequire(percentage.waitForExistence(timeout: 5), "Load basis must expose percentage mode.")
        try tapWhenReady(
            percentage,
            expectedLabels: ["Percentage of estimated one rep max"],
            invariant: "Selecting percentage mode exposes its editable percentage field."
        )

        return try existingPercentageField(in: app)
    }

    @MainActor
    private func existingPercentageField(in app: XCUIApplication) throws -> XCUIElement {
        let field = app.textFields["Percentage of estimated one rep max"].firstMatch
        if !(field.exists && field.isHittable) {
            for _ in 0..<8 where !(field.exists && field.isHittable) {
                acceptanceExpect(
                    ["routine-editor-scroll", "routine-editor-save-button"],
                    invariants: ["Scrolling keeps the routine editor interactive while revealing the percentage field."]
                )
                app.acceptanceSwipeUp(velocity: .fast)
            }
        }
        try acceptanceRequire(
            field.waitForExistence(timeout: 10) && waitUntil { field.isHittable },
            "Expected the percentage prescription field in the first visible routine set."
        )
        return field
    }

    @MainActor
    private func revealLoadBasis(in app: XCUIApplication) throws -> XCUIElement {
        let basis = app.buttons["Load basis"].firstMatch
        for _ in 0..<8 where !(basis.exists && basis.isHittable) {
            acceptanceExpect(
                ["routine-editor-scroll", "routine-editor-save-button"],
                invariants: ["Scrolling keeps the routine editor interactive while revealing its load-basis control."]
            )
            app.acceptanceSwipeUp(velocity: .fast)
        }
        try acceptanceRequire(
            basis.waitForExistence(timeout: 10) && waitUntil { basis.isHittable },
            "Expected a load-basis selector in the routine's strength sets."
        )
        return basis
    }

    // MARK: - Interaction support

    @MainActor
    private func enter(_ text: String, in field: XCUIElement, invalid: Bool) {
        acceptanceAssert(waitUntil { field.exists && field.isHittable }, "The percentage field must be ready for typing.")
        acceptanceExpect(
            invalid ? ["routine-set-load-invalid"] : ["routine-editor-save-button"],
            visibleLabels: ["Percentage of estimated one rep max"],
            invariants: ["The percentage field keeps every typed character without committing an invalid model value."]
        )
        field.acceptanceTap()
        // Select-all avoids an XCTest backspace burst outrunning SwiftUI's
        // local draft updates and manufacturing a fixture-only leftover value.
        field.typeKey("a", modifierFlags: .command)
        field.acceptanceTypeText(text)
        acceptanceAssert(waitUntil { field.value as? String == text }, "The field must keep every typed character.")
    }

    @MainActor
    private func blurField(
        in app: XCUIApplication,
        checkpoint: AcceptanceCheckpoint? = nil
    ) throws {
        let done = app.buttons["Done"].firstMatch
        try acceptanceRequire(done.waitForExistence(timeout: 5), "The routine number keyboard must expose Done.")
        if let checkpoint {
            try tapWhenReady(done, checkpoint: checkpoint)
        } else {
            try tapWhenReady(
                done,
                expectedLabels: ["Percentage of estimated one rep max"],
                invariant: "Blurring a valid percentage leaves the authored value visible."
            )
        }
        acceptanceAssert(waitUntil { !app.keyboards.firstMatch.exists }, "Done must dismiss the keyboard.")
    }

    private func invalidReceipt(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["routine-set-load-invalid"].firstMatch
    }

    @MainActor
    private func dismissInvalidAlertIfPresented(
        in app: XCUIApplication,
        checkpoint: AcceptanceCheckpoint
    ) {
        let alert = app.alerts["Check Routine Values"].firstMatch
        if alert.waitForExistence(timeout: 1) {
            expect(checkpoint)
            app.buttons["OK"].firstMatch.acceptanceTap()
            _ = waitUntil { !alert.exists }
        }
    }

    @MainActor
    private func tapWhenReady(
        _ element: XCUIElement,
        checkpoint: AcceptanceCheckpoint? = nil,
        expectedLabels: [String] = [],
        invariant: String? = nil,
        timeout: TimeInterval = 8
    ) throws {
        try acceptanceRequire(
            waitUntil(timeout: timeout) { element.exists && element.isHittable },
            "Element never became hittable: \(element)"
        )
        if let checkpoint {
            expect(checkpoint)
        } else {
            acceptanceExpect(
                visibleLabels: expectedLabels,
                invariants: invariant.map { [$0] } ?? []
            )
        }
        element.acceptanceTap()
    }

    private func expect(
        _ checkpoint: AcceptanceCheckpoint,
        oracles: [AcceptanceOracle] = []
    ) {
        acceptanceExpect(
            checkpoint.expectedVisibleIdentifiers,
            visibleLabels: checkpoint.expectedVisibleLabels,
            phase: checkpoint.phase,
            invariants: checkpoint.invariants,
            oracles: oracles
        )
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

    private func settle(for duration: TimeInterval) {
        RunLoop.current.run(until: Date.now.addingTimeInterval(duration))
    }
}
