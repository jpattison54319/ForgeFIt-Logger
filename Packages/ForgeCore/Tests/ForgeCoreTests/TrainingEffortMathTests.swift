import Testing
@testable import ForgeCore

struct TrainingEffortMathTests {
    @Test func rpeWinsThenRirThenNeutralDefault() {
        #expect(TrainingEffortMath.resolved(rpe: 9, rir: 4, defaultEffort: 8) == 9)
        #expect(TrainingEffortMath.resolved(rpe: nil, rir: 2, defaultEffort: 6) == 8)
        #expect(TrainingEffortMath.resolved(rpe: nil, rir: nil, defaultEffort: 8) == 8)
    }

    @Test func weightIsBoundedAndAnchoredAtRPEEight() {
        #expect(TrainingEffortMath.weight(for: 8) == 1)
        #expect(TrainingEffortMath.weight(for: 6) < 1)
        #expect(TrainingEffortMath.weight(for: 10) > 1)
        #expect(TrainingEffortMath.weight(for: -10) == 0.55)
        #expect(TrainingEffortMath.weight(for: 20) == 1.45)
    }
}
