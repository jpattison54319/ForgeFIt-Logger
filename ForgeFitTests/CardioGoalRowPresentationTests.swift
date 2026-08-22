import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

/// The routine editor's cardio goal row has to distinguish "no goal saved"
/// from "a goal is saved" without opening the builder. A row that reads
/// `Add goal` over a persisted 30-minute target is how a saved goal gets
/// silently re-entered or abandoned.
struct CardioGoalRowPresentationTests {
    @Test
    func offersToAddWhenNothingIsSaved() {
        let row = CardioGoalRowPresentation(planJSON: nil)
        #expect(row.action == "Add goal")
        #expect(row.summary == nil)
    }

    @Test
    func offersToAddWhenThePersistedPlanCarriesNoTarget() {
        let empty = IntervalPlan(steps: []).encodedJSON()
        let row = CardioGoalRowPresentation(planJSON: empty)
        #expect(row.action == "Add goal")
        #expect(row.summary == nil)
    }

    @Test
    func summarizesADurationGoal() {
        let plan = IntervalPlan(steps: [], goal: .init(kind: .duration, value: 30 * 60))
        let row = CardioGoalRowPresentation(planJSON: plan.encodedJSON())
        #expect(row.action == "Edit goal")
        #expect(row.summary == "30min goal")
    }

    @Test
    func summarizesACalorieGoal() {
        let plan = IntervalPlan(steps: [], goal: .init(kind: .calories, value: 400))
        let row = CardioGoalRowPresentation(planJSON: plan.encodedJSON())
        #expect(row.action == "Edit goal")
        #expect(row.summary == "400 kcal goal")
    }

    @Test
    func summarizesAZoneLockWithNoSessionGoal() {
        let plan = IntervalPlan(steps: [], hrZoneTarget: 2)
        let row = CardioGoalRowPresentation(planJSON: plan.encodedJSON())
        #expect(row.action == "Edit goal")
        #expect(row.summary == "Zone 2 lock")
    }

    @Test
    func summarizesAGoalHeldAlongsideAZoneLock() {
        let plan = IntervalPlan(
            steps: [],
            hrZoneTarget: 2,
            goal: .init(kind: .duration, value: 45 * 60)
        )
        let row = CardioGoalRowPresentation(planJSON: plan.encodedJSON())
        #expect(row.summary == "45min goal · Zone 2 lock")
    }

    @Test
    func summarizesAnIntervalStructure() {
        let plan = IntervalPlan.build(
            warmupSeconds: 300,
            repeats: 6,
            workSeconds: 60,
            recoverSeconds: 90,
            cooldownSeconds: 300
        )
        let row = CardioGoalRowPresentation(planJSON: plan.encodedJSON())
        #expect(row.action == "Edit goal")
        #expect(row.summary?.hasPrefix("6 × 1min / 1min 30s") == true)
    }

    /// Malformed JSON must degrade to the empty state rather than presenting
    /// an "Edit goal" row that opens onto nothing.
    @Test
    func treatsUndecodablePlansAsUnset() {
        let row = CardioGoalRowPresentation(planJSON: "{ not a plan }")
        #expect(row.action == "Add goal")
        #expect(row.summary == nil)
    }
}
