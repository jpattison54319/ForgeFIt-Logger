import Testing
@testable import ForgeCore

struct ExerciseMovementFamilyTests {
    @Test func lowerBodyMusclesOverrideLegacyPushPattern() {
        #expect(ExerciseMovementFamily.infer(
            movementPattern: "push",
            primaryMuscles: ["quadriceps", "glutes"]
        ) == .legs)
    }

    @Test func precisePatternsResolvePushPullAndCore() {
        #expect(ExerciseMovementFamily.infer(
            movementPattern: "horizontal_push",
            primaryMuscles: ["chest"]
        ) == .push)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: "vertical-pull",
            primaryMuscles: ["lats"]
        ) == .pull)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: "anti rotation",
            primaryMuscles: ["abdominals"]
        ) == .core)
    }

    @Test func primaryMusclesFillMissingPatterns() {
        #expect(ExerciseMovementFamily.infer(
            movementPattern: nil,
            primaryMuscles: ["front_delts", "triceps"]
        ) == .push)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: nil,
            primaryMuscles: ["rear_delts", "biceps"]
        ) == .pull)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: nil,
            primaryMuscles: ["abs"]
        ) == .core)
    }

    @Test func cardioAndAmbiguousMetadataAreHandledConservatively() {
        #expect(ExerciseMovementFamily.infer(
            movementPattern: "cardio",
            primaryMuscles: ["cardiovascular", "quadriceps"]
        ) == .cardio)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: nil,
            primaryMuscles: ["shoulders"]
        ) == nil)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: nil,
            primaryMuscles: ["chest", "lats"]
        ) == nil)
        #expect(ExerciseMovementFamily.infer(
            movementPattern: nil,
            primaryMuscles: []
        ) == nil)
    }
}
