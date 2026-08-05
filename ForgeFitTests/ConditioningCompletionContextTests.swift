import Testing
@testable import ForgeFit

struct ConditioningCompletionContextTests {
    @Test func mixedWorkoutConditioningUsesBlockScopedActions() {
        let context = ConditioningCompletionContext.block

        #expect(context.liveActionTitle == "Finish Conditioning")
        #expect(context.resultTitle == "Conditioning Result")
        #expect(context.commitTitle == "Complete Conditioning")
        #expect(context.returnTitle == "Back to Conditioning")
        #expect(context.minimizeAccessibilityLabel == "Return to mixed workout")
    }

    @Test func standaloneConditioningKeepsWorkoutScopedActions() {
        let context = ConditioningCompletionContext.workout

        #expect(context.liveActionTitle == "Finish Workout")
        #expect(context.resultTitle == "Workout Result")
        #expect(context.commitTitle == "Save Workout")
        #expect(context.returnTitle == "Keep Logging")
    }
}
