import Foundation
import Testing
@testable import ForgeCore

struct IntervalPlanTests {

    @Test func buildExpandsRepeats() {
        let plan = IntervalPlan.build(
            warmupSeconds: 600, repeats: 6, workSeconds: 180, recoverSeconds: 120, cooldownSeconds: 300
        )
        // warmup + 6 work + 5 recover (none after last work) + cooldown = 13
        #expect(plan.steps.count == 13)
        #expect(plan.steps.first?.kind == .warmup)
        #expect(plan.steps.last?.kind == .cooldown)
        #expect(plan.steps.filter { $0.kind == .work }.count == 6)
        #expect(plan.steps.filter { $0.kind == .recover }.count == 5)
        #expect(plan.totalSeconds == 600 + 6 * 180 + 5 * 120 + 300)
        #expect(plan.steps[1].label == "Work 1/6")
    }

    @Test func buildWithoutWarmupOrCooldown() {
        let plan = IntervalPlan.build(
            warmupSeconds: 0, repeats: 3, workSeconds: 60, recoverSeconds: 60, cooldownSeconds: 0
        )
        #expect(plan.steps.count == 5)
        #expect(plan.steps.first?.kind == .work)
        #expect(plan.steps.last?.kind == .work)
    }

    @Test func buildSteadyStateHasNoIntervalSteps() {
        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 0, workSeconds: 0, recoverSeconds: 0, cooldownSeconds: 0
        )
        #expect(plan.steps.count == 1)
        #expect(plan.steps[0].kind == .warmup)
    }

    @Test func jsonRoundTrip() {
        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 4, workSeconds: 240, recoverSeconds: 90, cooldownSeconds: 300
        )
        let json = plan.encodedJSON()
        #expect(json != nil)
        let decoded = IntervalPlan.decode(from: json)
        #expect(decoded == plan)
    }

    @Test func decodeNilAndGarbage() {
        #expect(IntervalPlan.decode(from: nil) == nil)
        #expect(IntervalPlan.decode(from: "not json") == nil)
    }
}
