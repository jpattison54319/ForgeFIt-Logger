import XCTest

/// The Insights Builder loop end to end: template gallery → canvas →
/// save → saved card on the tab → detail sheet.
final class InsightBuilderUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    private func launchApp(seedHistory: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--reset-store",
            "-didOnboard", "YES",
            "-weightUnitRaw", "kg",
            "-initialTab", "insights",
            "-quickActionBubble.v1", "",
        ]
        if seedHistory {
            app.launchArguments.insert("--seed-history", at: 1)
        }
        app.launch()
        return app
    }

    @MainActor
    private func openMyInsights(_ app: XCUIApplication) {
        let entry = element(app, "insight-my-insights-entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Expected the My Insights entry on the Insights tab.")
        entry.tap()
    }

    @MainActor
    private func openBlankBuilder(_ app: XCUIApplication) {
        openMyInsights(app)
        let build = element(app, "insight-build-button")
        XCTAssertTrue(build.waitForExistence(timeout: 5), "Expected the visible Build an insight action.")
        build.tap()
        XCTAssertTrue(
            element(app, "insight-metric-row-primary").waitForExistence(timeout: 5),
            "Expected the builder canvas."
        )
    }

    @MainActor
    @discardableResult
    private func scrollTo(
        _ target: XCUIElement,
        in app: XCUIApplication,
        maxSwipes: Int = 10,
        direction: SwipeDirection = .up
    ) -> Bool {
        var attempts = 0
        while (!target.exists || !target.isHittable), attempts < maxSwipes {
            switch direction {
            case .up: app.swipeUp()
            case .down: app.swipeDown()
            }
            attempts += 1
        }
        return target.exists
    }

    private enum SwipeDirection {
        case up
        case down
    }

    @MainActor
    private func chooseMetric(_ id: String, in app: XCUIApplication) {
        let metric = element(app, "insight-metric-\(id)")
        XCTAssertTrue(scrollTo(metric, in: app), "Expected \(id) in the compatible metric picker.")
        metric.tap()
    }

    @MainActor
    private func chooseTemplate(_ id: String, in app: XCUIApplication) {
        let template = element(app, "insight-template-\(id)")
        XCTAssertTrue(scrollTo(template, in: app), "Expected template \(id) in the gallery.")
        template.tap()
    }

    @MainActor
    func testTemplateToSavedCardRoundTrip() throws {
        let app = launchApp()

        // The Insights tab carries one compact entry; the page holds the rest.
        let entry = element(app, "insight-my-insights-entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "Expected the My Insights entry on the Insights tab.")
        entry.tap()

        // Fresh store → the pushed page opens on the template gallery.
        let template = element(app, "insight-template-template.checkinVsOutput")
        XCTAssertTrue(template.waitForExistence(timeout: 5), "Expected the template gallery on the My Insights page.")
        if !template.isHittable { app.swipeUp() }
        template.tap()

        // The canvas opens seeded and valid; the live preview may show an
        // honest empty state on a fresh store — save must still be enabled.
        let save = app.buttons.matching(identifier: "insight-builder-save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Expected the builder canvas.")
        XCTAssertTrue(save.isEnabled, "A template recipe must validate as-is.")
        save.tap()

        // The saved card lands in My Insights.
        let card = element(app, "insight-card-Check-ins vs volume")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Expected the saved insight card.")

        // Opening it presents the full result sheet.
        card.tap()
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Expected the insight detail sheet.")
        done.tap()

        // Its ⋯ menu offers the management actions (a sibling of the open
        // button now, so query it at app level).
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Options for'")
        ).firstMatch.tap()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 3), "Expected card management menu.")
        app.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons["Delete Insight"].waitForExistence(timeout: 3), "Expected the consequence dialog.")
        app.buttons["Delete Insight"].tap()
        XCTAssertFalse(
            element(app, "insight-card-Check-ins vs volume").waitForExistence(timeout: 3),
            "Expected the card gone after delete."
        )
    }

    /// Mixed-unit trend end to end against seeded history: daily buckets are
    /// rest-day-dominated, so indexing is refused with the named warning and
    /// native units; weekly buckets index onto one shared scale.
    @MainActor
    func testMixedUnitTrendRefusesZeroDominatedDailyIndexThenIndexesWeekly() throws {
        let app = launchApp(seedHistory: true)

        let entry = element(app, "insight-my-insights-entry")
        XCTAssertTrue(entry.waitForExistence(timeout: 8), "Expected the My Insights entry on the Insights tab.")
        entry.tap()

        let build = element(app, "insight-build-button")
        XCTAssertTrue(build.waitForExistence(timeout: 5), "Expected the build button on the My Insights page.")
        build.tap()

        // Primary stays the canvas default (Working volume, mass). Alongside:
        // Workout duration — a different axis family, so the builder must
        // switch to indexing. The picker list is lazy; scroll until the
        // Strength section is on screen.
        let primaryRow = element(app, "insight-metric-row-primary")
        XCTAssertTrue(primaryRow.waitForExistence(timeout: 5), "Expected the builder canvas.")
        XCTAssertEqual(primaryRow.label, "Working volume", "Expected the blank canvas to default to Working volume.")

        element(app, "insight-add-comparison").tap()
        let durationChoice = element(app, "insight-metric-strength.duration")
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'insight-metric-'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Expected the comparison metric picker."
        )
        var scrolls = 0
        while !durationChoice.exists, scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(durationChoice.exists, "Expected Workout duration in the metric picker.")
        durationChoice.tap()

        app.buttons["12W"].firstMatch.tap()
        app.buttons["Day"].firstMatch.tap()

        // Daily: training ~2 of 7 days means both index anchors are mostly
        // zeros — the preview must say why one shared scale was refused.
        let refusal = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "can't anchor one shared scale")
        ).firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 8), "Expected the zero-dominated index warning by Day.")

        // Weekly: every week has training, so the same recipe indexes onto
        // one shared chart, disclosed by the indexing caption.
        app.buttons["Week"].firstMatch.tap()
        let indexedCaption = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "100 = each line's average")
        ).firstMatch
        XCTAssertTrue(indexedCaption.waitForExistence(timeout: 8), "Expected the mean-indexed caption by Week.")
        XCTAssertFalse(refusal.exists, "The refusal warning must clear once weekly buckets index cleanly.")
    }

    /// Builds a real three-series trend through the same visible controls a
    /// user sees, then verifies that the saved detail keeps both the chart and
    /// its tabular alternative discoverable to assistive technologies.
    @MainActor
    func testBuildsMultiMetricTrendWithPersistentScopesAndAccessibleDataDisclosure() throws {
        let app = launchApp(seedHistory: true)
        openBlankBuilder(app)

        let primaryScope = element(app, "insight-scope-primary")
        XCTAssertTrue(primaryScope.waitForExistence(timeout: 3), "Working volume must expose its visible scope control.")
        XCTAssertTrue(primaryScope.label.localizedCaseInsensitiveContains("All data"))

        element(app, "insight-add-comparison").tap()
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'insight-metric-'")
            ).firstMatch.waitForExistence(timeout: 5),
            "Expected the comparison picker."
        )
        XCTAssertFalse(
            element(app, "insight-metric-strength.volume").exists,
            "The already-selected unscoped metric must not be offered as an invalid duplicate."
        )
        chooseMetric("strength.duration", in: app)

        let durationRow = element(app, "insight-metric-row-comparison-0")
        XCTAssertTrue(durationRow.waitForExistence(timeout: 4))
        XCTAssertEqual(durationRow.label, "Workout duration")
        let durationScope = element(app, "insight-scope-comparison-0")
        XCTAssertTrue(durationScope.exists, "Each independently scoped operand needs its own state-stable control.")

        element(app, "insight-add-comparison").tap()
        chooseMetric("strength.workingSets", in: app)

        let setRow = element(app, "insight-metric-row-comparison-1")
        XCTAssertTrue(setRow.waitForExistence(timeout: 4))
        XCTAssertEqual(setRow.label, "Working sets")
        XCTAssertTrue(element(app, "insight-scope-comparison-1").exists)
        XCTAssertTrue(primaryScope.exists, "Adding more operands must not make the primary scope control disappear.")

        // Changing alignment must not replace or hide the operand controls.
        let week = app.buttons["Week"].firstMatch
        XCTAssertTrue(scrollTo(week, in: app))
        week.tap()
        XCTAssertTrue(primaryScope.exists)
        XCTAssertTrue(durationScope.exists)

        let name = "UI multi-metric trend"
        let nameField = element(app, "insight-name-field")
        XCTAssertTrue(scrollTo(nameField, in: app, direction: .down))
        nameField.tap()
        nameField.typeText(name)

        let save = app.buttons.matching(identifier: "insight-builder-save").firstMatch
        XCTAssertTrue(save.isEnabled, "Three compatible series should remain saveable.")
        save.tap()

        let card = element(app, "insight-card-\(name)")
        XCTAssertTrue(card.waitForExistence(timeout: 6), "Expected the saved multi-metric card.")
        card.tap()

        let chart = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Insight chart.")
        ).firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "The rendered chart needs a spoken chart summary.")

        let viewData = app.buttons["View data"].firstMatch
        XCTAssertTrue(scrollTo(viewData, in: app), "A visible View data alternative must accompany the chart.")
        XCTAssertTrue(viewData.isEnabled)
        viewData.tap()
        XCTAssertEqual(viewData.value as? String, "Expanded")
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Working volume ·")
            ).firstMatch.waitForExistence(timeout: 4),
            "Expanding View data should expose named, dated values instead of a visual-only chart."
        )
    }

    /// Required-unit metrics are intentionally atomic: selecting pace or
    /// power immediately asks for one real cardio type, and impossible
    /// duplicate metric/scope pairs are absent rather than rejected later.
    @MainActor
    func testPaceAndPowerRequireModalityAndSaveOnlyWhenRecipeIsComplete() throws {
        let app = launchApp(seedHistory: true)
        openBlankBuilder(app)

        app.buttons["Relationship"].firstMatch.tap()
        let save = app.buttons.matching(identifier: "insight-builder-save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled, "A relationship without its second operand is incomplete.")

        element(app, "insight-add-comparison").tap()
        XCTAssertTrue(
            element(app, "insight-metric-cardio.pace").waitForExistence(timeout: 5),
            "Expected compatible relationship metrics."
        )
        XCTAssertFalse(
            element(app, "insight-metric-strength.volume").exists,
            "The existing unscoped primary must not be offered as the same comparison operand."
        )
        chooseMetric("cardio.pace", in: app)

        XCTAssertTrue(app.navigationBars["Pace"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Choose one cardio type"].exists)
        XCTAssertFalse(app.buttons["Everything"].exists)
        XCTAssertFalse(app.buttons["Exercise…"].exists)
        let runForPace = element(app, "insight-required-modality-run")
        XCTAssertTrue(runForPace.waitForExistence(timeout: 3))
        runForPace.tap()

        let paceScope = element(app, "insight-scope-comparison-0")
        XCTAssertTrue(paceScope.waitForExistence(timeout: 4))
        XCTAssertTrue(paceScope.label.localizedCaseInsensitiveContains("Run"))
        XCTAssertTrue(save.isEnabled, "Choosing the required pace modality should complete the recipe.")

        // Replace the primary with power. The picker must collect its unit
        // domain before returning to the canvas as well.
        element(app, "insight-metric-row-primary").tap()
        chooseMetric("cardio.power", in: app)
        XCTAssertTrue(app.navigationBars["Average power"].waitForExistence(timeout: 3))
        let runForPower = element(app, "insight-required-modality-run")
        XCTAssertTrue(runForPower.waitForExistence(timeout: 3))
        runForPower.tap()

        let powerScope = element(app, "insight-scope-primary")
        XCTAssertTrue(powerScope.waitForExistence(timeout: 4))
        XCTAssertTrue(powerScope.label.localizedCaseInsensitiveContains("Run"))
        XCTAssertTrue(paceScope.exists, "The comparison's scope control must survive replacement of the primary metric.")
        XCTAssertTrue(save.isEnabled)

        // The same Power · Run operand is not a legal duplicate. Power stays
        // discoverable because another modality could be valid, but Run is
        // removed and the picker explains that no unused history remains.
        element(app, "insight-metric-row-comparison-0").tap()
        chooseMetric("cardio.power", in: app)
        XCTAssertTrue(app.navigationBars["Average power"].waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "insight-required-modality-run").exists)
        XCTAssertTrue(app.staticTexts["No matching history"].waitForExistence(timeout: 3))
        app.buttons["Metrics"].tap()
        app.navigationBars["Choose metric"].buttons["Cancel"].tap()

        XCTAssertTrue(powerScope.waitForExistence(timeout: 3))
        XCTAssertTrue(paceScope.exists)
        XCTAssertTrue(save.isEnabled, "Canceling an impossible replacement must preserve the last valid recipe.")
    }

    /// A period recipe represents two raw equal windows. Day/week/session
    /// bucketing is therefore intentionally absent, and a mixed-unit template
    /// renders value cards rather than implying one shared y-axis.
    @MainActor
    func testPeriodTemplateHidesGroupingAndUsesReadableMixedUnitCards() throws {
        let app = launchApp(seedHistory: true)
        openMyInsights(app)
        chooseTemplate("template.fourWeekComparison", in: app)

        let save = app.buttons.matching(identifier: "insight-builder-save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Compares two equal 4W windows")
            ).firstMatch.exists
        )

        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "By")).firstMatch.exists,
            "Whole-period aggregation must not expose a meaningless bucket heading."
        )
        XCTAssertFalse(app.buttons["Day"].exists)
        XCTAssertFalse(app.buttons["Week"].exists)
        XCTAssertFalse(app.buttons["Session"].exists)

        let periodCardEvidence = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "current /", "previous records")
        ).firstMatch
        XCTAssertTrue(
            scrollTo(periodCardEvidence, in: app),
            "Mixed period units should fall back to per-metric value cards with explicit sample counts."
        )
        XCTAssertFalse(
            app.otherElements.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Previous Working volume")
            ).firstMatch.exists,
            "The mixed-unit result must not expose shared-axis bar marks."
        )
    }

    /// Templates that contain required semantic scopes collect those choices
    /// before opening the builder, then visibly apply the chosen domain to
    /// every compatible operand.
    @MainActor
    func testTemplatesResolveExerciseAndModalityBeforeOpeningValidCanvas() throws {
        let app = launchApp(seedHistory: true)
        openMyInsights(app)

        chooseTemplate("template.bodyweightVsE1RM", in: app)
        XCTAssertTrue(app.navigationBars["Choose exercise"].waitForExistence(timeout: 4))
        let chestPress = element(
            app,
            "insight-template-exercise-00000000-0000-7000-8000-000000000206"
        )
        XCTAssertTrue(scrollTo(chestPress, in: app), "Expected a history-backed exercise choice.")
        chestPress.tap()

        let save = app.buttons.matching(identifier: "insight-builder-save").firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(
            element(app, "insight-metric-row-primary").label.contains("Machine Chest Press")
        )
        XCTAssertTrue(
            element(app, "insight-scope-primary").label.contains("Machine Chest Press")
        )
        app.buttons["Cancel"].tap()

        chooseTemplate("template.paceVsHeartRate", in: app)
        XCTAssertTrue(app.navigationBars["Choose cardio type"].waitForExistence(timeout: 4))
        element(app, "insight-template-modality-run").tap()

        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        let primaryScope = element(app, "insight-scope-primary")
        let comparisonScope = element(app, "insight-scope-comparison-0")
        XCTAssertTrue(primaryScope.waitForExistence(timeout: 3))
        XCTAssertTrue(comparisonScope.exists)
        XCTAssertTrue(primaryScope.label.localizedCaseInsensitiveContains("Run"))
        XCTAssertTrue(comparisonScope.label.localizedCaseInsensitiveContains("Run"))
    }

    /// Relationship population is a visible, state-stable math choice only
    /// when a training total can be structurally zero. Health measurements
    /// never expose a control that could manufacture missing readings.
    @MainActor
    func testRelationshipPopulationDefaultsToTrainingDaysAndHidesForHealthOnly() throws {
        let app = launchApp(seedHistory: true)
        openBlankBuilder(app)

        app.buttons["Relationship"].firstMatch.tap()
        element(app, "insight-add-comparison").tap()
        chooseMetric("health.sleepTotal", in: app)

        let trainingDays = element(app, "insight-population-activeBucketsOnly")
        let allMeasuredDays = element(app, "insight-population-includeInactiveBuckets")
        XCTAssertTrue(scrollTo(trainingDays, in: app), "A volume relationship needs a visible population choice.")
        XCTAssertTrue(trainingDays.isSelected, "Automatic population should resolve to training days.")
        XCTAssertTrue(allMeasuredDays.exists)
        XCTAssertTrue(app.staticTexts["Not enough overlap yet"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "matched days to create insight")
            ).firstMatch.exists
        )
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "isn't on the chart")
            ).firstMatch.exists,
            "The insufficient-overlap preview must not repeat its explanation as a warning."
        )

        allMeasuredDays.tap()
        XCTAssertTrue(allMeasuredDays.isSelected)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "count as 0")
            ).firstMatch.waitForExistence(timeout: 3),
            "The selected population must state the zero consequence inline."
        )

        let primary = element(app, "insight-metric-row-primary")
        XCTAssertTrue(scrollTo(primary, in: app, direction: .down))
        primary.tap()
        chooseMetric("health.hrv", in: app)

        XCTAssertFalse(
            trainingDays.exists || allMeasuredDays.exists,
            "Health-only relationships must always use recorded overlap without a zero override."
        )
    }
}
