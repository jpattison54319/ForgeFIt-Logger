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

// MARK: - Per-step zones, rounds, summaries

extension IntervalPlanTests {
    @Test func buildAppliesPerStepZonesToWorkAndRecoverOnly() {
        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 4, workSeconds: 240, recoverSeconds: 180,
            cooldownSeconds: 300, workZone: 4, recoverZone: 3
        )
        #expect(plan.steps.first { $0.kind == .warmup }?.hrZone == nil)
        #expect(plan.steps.filter { $0.kind == .work }.allSatisfy { $0.hrZone == 4 })
        #expect(plan.steps.filter { $0.kind == .recover }.allSatisfy { $0.hrZone == 3 })
        #expect(plan.steps.first { $0.kind == .cooldown }?.hrZone == nil)
    }

    /// Plans encoded before per-step zones existed must still decode.
    @Test func legacyJSONWithoutStepZonesDecodes() {
        let legacy = """
        {"steps":[{"id":"\(UUID().uuidString)","kind":"work","seconds":60,"label":"Work 1/1"}],"hrZoneTarget":2}
        """
        let plan = IntervalPlan.decode(from: legacy)
        #expect(plan?.steps.first?.hrZone == nil)
        #expect(plan?.hrZoneTarget == 2)
    }

    @Test func stepZonesRoundTripThroughJSON() {
        let plan = IntervalPlan.build(
            warmupSeconds: 0, repeats: 2, workSeconds: 30, recoverSeconds: 30,
            cooldownSeconds: 0, workZone: 5
        )
        let decoded = IntervalPlan.decode(from: plan.encodedJSON())
        #expect(decoded == plan)
    }

    @Test func roundInfoTracksWorkBlocks() {
        let plan = IntervalPlan.build(
            warmupSeconds: 300, repeats: 3, workSeconds: 60, recoverSeconds: 60, cooldownSeconds: 300
        )
        // Steps: warmup, W1, R1, W2, R2, W3, cooldown
        #expect(plan.roundInfo(at: 0) == nil)          // warm-up: no round yet
        #expect(plan.roundInfo(at: 1)! == (1, 3))      // Work 1
        #expect(plan.roundInfo(at: 2)! == (1, 3))      // Recover after work 1
        #expect(plan.roundInfo(at: 5)! == (3, 3))      // Work 3
        #expect(plan.roundInfo(at: 6)! == (3, 3))      // cooldown keeps last round
        #expect(plan.roundInfo(at: 99) == nil)         // out of range
    }

    @Test func structureSummaryReadsLikeAWorkout() {
        let intervals = IntervalPlan.build(
            warmupSeconds: 300, repeats: 10, workSeconds: 60, recoverSeconds: 90, cooldownSeconds: 300
        )
        #expect(intervals.structureSummary == "10 × 1min / 1min 30s · 33min 30s total")

        let zoneOnly = IntervalPlan(steps: [], hrZoneTarget: 2)
        #expect(zoneOnly.structureSummary == "Zone 2 lock")

        let open = IntervalPlan(steps: [])
        #expect(open.structureSummary == "Open")
    }
}
