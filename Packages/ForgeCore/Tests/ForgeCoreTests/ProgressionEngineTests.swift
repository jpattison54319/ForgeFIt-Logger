import Foundation
import Testing
@testable import ForgeCore

struct ProgressionEngineTests {

    private let lb = ProgressionIncrement(displayPerKilogram: 2.2046226218, stepDisplay: 5, suffix: "lb")
    private let kg = ProgressionIncrement(displayPerKilogram: 1, stepDisplay: 2.5, suffix: "kg")

    private func input(
        sets: [(kg: Double?, reps: Int?)],
        low: Int? = 8, high: Int? = 10,
        rule: ProgressionRule = .doubleProgression,
        increment: ProgressionIncrement? = nil,
        bodyweight: Bool = false
    ) -> ProgressionInput {
        ProgressionInput(
            lastSessionSets: sets.map { .init(weightKg: $0.kg, reps: $0.reps) },
            targetRepsLow: low, targetRepsHigh: high,
            rule: rule, increment: increment ?? lb, isBodyweight: bodyweight
        )
    }

    /// Topping the range on every set earns exactly one clean display-unit
    /// step — 110 lb stored as noisy kg must come back as exactly 115 lb.
    @Test func toppedRangeIncreasesByOneCleanStep() {
        let kg110lb = 110 / lb.displayPerKilogram
        let out = ProgressionEngine.suggest(input(sets: [(kg110lb, 10), (kg110lb, 11)]))
        #expect(out?.kind == .increase)
        let display = (out?.weightKg ?? 0) * lb.displayPerKilogram
        #expect(abs(display - 115) < 0.001)
        #expect(out?.repsLow == 8)
        #expect(out?.rationale.contains("+5 lb") == true)
    }

    @Test func inRangeSuggestsMoreReps_underRangeHolds() {
        let inRange = ProgressionEngine.suggest(input(sets: [(50, 9), (50, 8)]))
        #expect(inRange?.kind == .addReps)

        let under = ProgressionEngine.suggest(input(sets: [(50, 6), (50, 7), (50, 9)]))
        #expect(under?.kind == .hold)
        #expect(under?.weightKg == 50)
    }

    @Test func fixedAndPercentRules() {
        let fixed = ProgressionEngine.suggest(
            input(sets: [(100, 8), (100, 8)], rule: .fixedIncrement(step: 2.5), increment: kg)
        )
        #expect(fixed?.kind == .increase)
        #expect(abs((fixed?.weightKg ?? 0) - 102.5) < 0.001)

        // 2% of 100 kg = 102 → snaps to the 2.5 kg grid, guaranteed forward.
        let pct = ProgressionEngine.suggest(
            input(sets: [(100, 8)], rule: .percent(step: 2), increment: kg)
        )
        #expect(pct?.kind == .increase)
        #expect(abs((pct?.weightKg ?? 0) - 102.5) < 0.001)

        let missed = ProgressionEngine.suggest(
            input(sets: [(100, 6)], rule: .fixedIncrement(step: 2.5), increment: kg)
        )
        #expect(missed?.kind == .hold)
    }

    @Test func bodyweightProgressesRepsOnly() {
        let out = ProgressionEngine.suggest(input(sets: [(nil, 10), (nil, 12)], bodyweight: true))
        #expect(out?.kind == .addReps)
        #expect(out?.weightKg == nil)
        #expect(out?.repsLow == 9)
        #expect(out?.repsHigh == 11)
    }

    @Test func noHistoryOrOffRuleYieldsNil() {
        #expect(ProgressionEngine.suggest(input(sets: [])) == nil)
        #expect(ProgressionEngine.suggest(input(sets: [(nil, nil)])) == nil)
        #expect(ProgressionEngine.suggest(input(sets: [(100, 10)], rule: .off)) == nil)
    }

    /// Without a programmed rep range, last session anchors the range.
    @Test func missingRangeAnchorsOnLastSession() {
        let out = ProgressionEngine.suggest(input(sets: [(60, 8), (60, 8)], low: nil, high: nil))
        #expect(out?.kind == .addReps)
        #expect(out?.repsLow == 8)
        #expect(out?.repsHigh == 10)
    }

    @Test func ruleJSONRoundTrips() {
        for rule: ProgressionRule in [.doubleProgression, .fixedIncrement(step: 5), .percent(step: 2.5), .off] {
            #expect(ProgressionRule.decode(from: rule.encodedJSON()) == rule)
        }
        #expect(ProgressionRule.decode(from: nil) == nil)
    }
}
