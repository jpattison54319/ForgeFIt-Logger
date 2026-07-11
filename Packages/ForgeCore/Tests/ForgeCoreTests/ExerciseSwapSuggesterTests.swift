import Foundation
import Testing
@testable import ForgeCore

struct ExerciseSwapSuggesterTests {

    private func candidate(
        _ name: String,
        pattern: String? = nil,
        primary: [String],
        secondary: [String] = [],
        equipment: String? = nil,
        mechanic: String? = nil,
        force: String? = nil
    ) -> ExerciseSwapSuggester.Candidate {
        .init(
            id: UUID(),
            name: name,
            movementPattern: pattern,
            primaryMuscles: primary,
            secondaryMuscles: secondary,
            equipment: equipment,
            mechanic: mechanic,
            force: force
        )
    }

    /// The "machine is taken" case: a machine press should lead with same-
    /// muscle free-weight presses, flag them as machine-free alternatives, and
    /// never suggest exercises for other muscles.
    @Test func machinePressSuggestsFreeWeightChestWork() {
        let target = candidate("Chest Press (Machine)", pattern: "horizontal push",
                               primary: ["chest"], secondary: ["triceps"],
                               equipment: "machine", mechanic: "compound", force: "push")
        let bench = candidate("Barbell Bench Press", pattern: "horizontal push",
                              primary: ["chest"], secondary: ["triceps"],
                              equipment: "barbell", mechanic: "compound", force: "push")
        let fly = candidate("Dumbbell Fly", primary: ["chest"],
                            equipment: "dumbbell", mechanic: "isolation", force: "push")
        let legPress = candidate("Leg Press", primary: ["quadriceps"],
                                 equipment: "machine", mechanic: "compound", force: "push")
        let row = candidate("Seated Cable Row", primary: ["back"],
                            equipment: "cable", mechanic: "compound", force: "pull")

        let out = ExerciseSwapSuggester.suggest(replacing: target, from: [row, legPress, fly, bench])
        #expect(out.map(\.candidate.name) == ["Barbell Bench Press", "Dumbbell Fly"])
        #expect(out[0].facets.contains(.samePattern))
        #expect(out[0].facets.contains(.freeWeightAlternative("barbell")))
        #expect(out[1].facets.contains(.freeWeightAlternative("dumbbell")))
    }

    /// History breaks ties: an exercise the lifter has done before outranks an
    /// otherwise-identical stranger, and carries the trainedBefore facet.
    @Test func trainedExerciseOutranksIdenticalStranger() {
        let target = candidate("Lat Pulldown", primary: ["back"], equipment: "cable")
        let known = candidate("Pull-Up", primary: ["back"], equipment: "body only")
        let unknown = candidate("Chin-Up", primary: ["back"], equipment: "body only")

        let out = ExerciseSwapSuggester.suggest(
            replacing: target, from: [unknown, known], trainedIDs: [known.id]
        )
        #expect(out.first?.candidate.name == "Pull-Up")
        #expect(out.first?.facets.contains(.trainedBefore) == true)
        #expect(out.last?.facets.contains(.trainedBefore) == false)
    }

    @Test func equipmentPreferenceReordersCloseMatchesWithoutBeatingMovementQuality() {
        let target = candidate("Machine Chest Press", pattern: "horizontal push",
                               primary: ["chest"], equipment: "machine")
        let strongMachine = candidate("Leverage Chest Press", pattern: "horizontal push",
                                      primary: ["chest"], equipment: "leverage machine")
        let closeDumbbell = candidate("Dumbbell Bench Press", pattern: "horizontal push",
                                     primary: ["chest"], equipment: "dumbbell")
        let weakDumbbell = candidate("Dumbbell Fly", primary: ["chest"], equipment: "dumbbell")

        let out = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: [strongMachine, weakDumbbell, closeDumbbell],
            preference: .freeWeights
        )

        #expect(out.first?.candidate.name == "Dumbbell Bench Press")
        #expect(out.first?.facets.contains(.preferredEquipment("dumbbell")) == true)
        #expect(out.last?.candidate.name == "Dumbbell Fly")
    }

    @Test func trainingHistoryOnlyBreaksNearTies() {
        let target = candidate("Bench Press", pattern: "horizontal push",
                               primary: ["chest"], equipment: "barbell")
        let strong = candidate("Dumbbell Bench Press", pattern: "horizontal push",
                               primary: ["chest"], equipment: "dumbbell")
        let familiarButWeak = candidate("Cable Fly", primary: ["chest"], equipment: "cable")

        let out = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: [familiarButWeak, strong],
            trainedIDs: [familiarButWeak.id]
        )

        #expect(out.first?.candidate.name == "Dumbbell Bench Press")
    }

    @Test func onlyViableDifferentEquipmentPreferencesAreOffered() {
        let target = candidate("Chest Press", primary: ["chest"], equipment: "machine")
        let dumbbell = candidate("Dumbbell Bench Press", primary: ["chest"], equipment: "dumbbell")
        let unrelatedBodyweight = candidate("Air Squat", primary: ["quadriceps"], equipment: "body only")

        let preferences = ExerciseSwapSuggester.availablePreferences(
            replacing: target,
            from: [dumbbell, unrelatedBodyweight]
        )

        #expect(preferences == [.freeWeights])
    }

    /// Self, exercises already in the workout, and the limit are all honored.
    @Test func excludesSelfAndInUseAndRespectsLimit() {
        let target = candidate("Squat", primary: ["quadriceps"], equipment: "barbell")
        let pool = (1...10).map {
            candidate("Quad Exercise \($0)", primary: ["quadriceps"], equipment: "dumbbell")
        }
        let excluded = pool[0]

        var out = ExerciseSwapSuggester.suggest(
            replacing: target, from: pool + [target], excluding: [excluded.id]
        )
        #expect(out.count == 6)
        #expect(!out.map(\.candidate.id).contains(target.id))
        #expect(!out.map(\.candidate.id).contains(excluded.id))

        out = ExerciseSwapSuggester.suggest(replacing: target, from: pool, limit: 3)
        #expect(out.count == 3)
    }

    /// A target with no primary muscles can't be matched honestly — empty out.
    @Test func noPrimaryMusclesYieldsNoSuggestions() {
        let target = candidate("Mystery Movement", primary: [])
        let pool = [candidate("Barbell Bench Press", primary: ["chest"])]
        #expect(ExerciseSwapSuggester.suggest(replacing: target, from: pool).isEmpty)
    }
}
