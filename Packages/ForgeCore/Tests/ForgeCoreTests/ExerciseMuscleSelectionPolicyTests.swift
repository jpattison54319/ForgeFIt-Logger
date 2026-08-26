import Testing
@testable import ForgeCore

struct ExerciseMuscleSelectionPolicyTests {
    @Test func exactAndAliasEquivalentMusclesOverlap() {
        #expect(ExerciseMuscleSelectionPolicy.overlaps("biceps", "Biceps"))
        #expect(ExerciseMuscleSelectionPolicy.overlaps("front_delts", "front delts"))
        #expect(!ExerciseMuscleSelectionPolicy.overlaps("biceps", "triceps"))
    }

    @Test func broadParentsAndSpecificChildrenOverlap() {
        #expect(ExerciseMuscleSelectionPolicy.overlaps("back", "lats"))
        #expect(ExerciseMuscleSelectionPolicy.overlaps("rear delts", "shoulders"))
        #expect(!ExerciseMuscleSelectionPolicy.overlaps("lats", "traps"))
    }

    @Test func secondaryMusclesExcludePrimaryScopeAndCanonicalDuplicates() {
        let result = ExerciseMuscleSelectionPolicy.secondaryMuscles(
            from: ["lats", "BICEPS", "biceps", "forearms"],
            excluding: "back"
        )

        #expect(result == ["biceps", "forearms"])
    }
}
