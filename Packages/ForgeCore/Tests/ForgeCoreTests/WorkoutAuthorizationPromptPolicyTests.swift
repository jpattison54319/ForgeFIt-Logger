import Testing
@testable import ForgeCore

struct WorkoutAuthorizationPromptPolicyTests {
    @Test func connectedWorkoutNeverRepromptsForNewReadTypes() {
        #expect(!WorkoutAuthorizationPromptPolicy.shouldRequestAtWorkoutStart(
            hasWorkoutWriteAccess: true,
            hasUndecidedTypes: true
        ))
    }

    @Test func firstWorkoutCanRequestUndecidedAccess() {
        #expect(WorkoutAuthorizationPromptPolicy.shouldRequestAtWorkoutStart(
            hasWorkoutWriteAccess: false,
            hasUndecidedTypes: true
        ))
    }

    @Test func decidedDenialDoesNotRepromptAtWorkoutStart() {
        #expect(!WorkoutAuthorizationPromptPolicy.shouldRequestAtWorkoutStart(
            hasWorkoutWriteAccess: false,
            hasUndecidedTypes: false
        ))
    }
}
