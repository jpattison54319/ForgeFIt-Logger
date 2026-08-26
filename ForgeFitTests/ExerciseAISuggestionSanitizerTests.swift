import ForgeCore
import Testing
@testable import ForgeFit

struct ExerciseAISuggestionSanitizerTests {
    @Test func latPrayerDropsBroadParentsAndSpeculativeSecondaries() {
        let result = ExerciseAISuggestionSanitizer.sanitize(
            name: "Lat Prayer",
            primary: ["lats", "back", "traps"],
            secondary: ["shoulders", "biceps", "chest", "forearms"],
            isCardio: false
        )

        #expect(result.primary == ["lats"])
        #expect(result.secondary.isEmpty)
    }

    @Test func abductionRejectsAnUnrelatedObliqueSuggestion() {
        let result = ExerciseAISuggestionSanitizer.sanitize(
            name: "Lean Back Abduction Machine",
            primary: ["abductors"],
            secondary: ["obliques", "glutes", "hamstrings"],
            isCardio: false
        )

        #expect(result.primary == ["abductors"])
        #expect(result.secondary == ["glutes"])
    }

    @Test func anUnknownPrimaryFailsClosedInsteadOfKeepingArbitrarySecondaries() {
        let result = ExerciseAISuggestionSanitizer.sanitize(
            name: "Mystery Neck Handle",
            primary: ["neck"],
            secondary: ["chest", "obliques"],
            isCardio: false
        )

        #expect(result.primary == ["neck"])
        #expect(result.secondary.isEmpty)
    }

    @Test func anExplicitExerciseNameCorrectsAConflictingModelGuess() {
        let result = ExerciseAISuggestionSanitizer.sanitize(
            name: "Lat Prayer",
            primary: ["chest"],
            secondary: ["triceps"],
            isCardio: false
        )

        #expect(result.primary == ["lats"])
        #expect(result.secondary.isEmpty)
    }

    @Test func broadPrimaryDoesNotRepeatItsChildAsSecondary() {
        let result = ExerciseAISuggestionSanitizer.sanitize(
            name: "Supported Row",
            primary: ["back"],
            secondary: ["lats", "biceps"],
            isCardio: false
        )

        #expect(result.primary == ["back"])
        #expect(result.secondary == ["biceps"])
    }

    @Test func hipFlexorsAreAcceptedWithoutRestoringTheLegacyHipsRegion() {
        let result = ExerciseAISuggestionSanitizer.sanitize(
            name: "Standing Hip Flexion",
            primary: ["hip flexors", "hips"],
            secondary: ["spine"],
            isCardio: false
        )

        #expect(result.primary == ["hip flexors"])
        #expect(result.secondary.isEmpty)
    }

    @Test func lowConfidenceGuessesCanBeCorrectedButTrustedDisjointGuessesArePreserved() {
        #expect(ExerciseAISuggestionSanitizer.shouldAcceptSuggestedPrimary(
            ["chest"],
            existing: ["abductors"],
            existingConfidence: ExerciseClassifier.reviewConfidenceThreshold - 0.01
        ))
        #expect(!ExerciseAISuggestionSanitizer.shouldAcceptSuggestedPrimary(
            ["chest"],
            existing: ["abductors"],
            existingConfidence: ExerciseClassifier.reviewConfidenceThreshold
        ))
        #expect(ExerciseAISuggestionSanitizer.shouldAcceptSuggestedPrimary(
            ["lats"],
            existing: ["upper back"],
            existingConfidence: 1
        ))
    }
}
