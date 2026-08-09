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
        weightMode: WeightMode = .external,
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
            weightMode: weightMode,
            mechanic: mechanic,
            force: force
        )
    }

    @Test func machinePressSuggestsChestWorkAndExcludesOtherRegions() {
        let target = candidate(
            "Chest Press (Machine)", pattern: "horizontal push",
            primary: ["chest"], secondary: ["triceps"],
            equipment: "machine", mechanic: "compound", force: "push"
        )
        let bench = candidate(
            "Barbell Bench Press", pattern: "horizontal push",
            primary: ["chest"], secondary: ["triceps"],
            equipment: "barbell", mechanic: "compound", force: "push"
        )
        let fly = candidate("Dumbbell Fly", primary: ["chest"], equipment: "dumbbell")
        let row = candidate("Seated Cable Row", primary: ["back"], equipment: "cable")

        let output = ExerciseSwapSuggester.suggest(replacing: target, from: [row, fly, bench])

        #expect(output.map(\.candidate.name) == ["Barbell Bench Press", "Dumbbell Fly"])
    }

    @Test func middleBackAliasesAndRelatedBackPrimariesProducePullMatches() {
        let target = candidate(
            "Newtech Adjustable Low Pulley",
            pattern: "horizontal pull",
            primary: ["middle back"],
            secondary: ["upper back", "lats", "biceps"],
            equipment: "machine"
        )
        let seededAlias = candidate(
            "Seated Cable Row", pattern: "horizontal pull",
            primary: ["mid_back"], secondary: ["lats", "biceps"], equipment: "cable"
        )
        let upperBack = candidate(
            "Chest-Supported Row", pattern: "horizontal pull",
            primary: ["upper back"], secondary: ["biceps"], equipment: "dumbbell"
        )
        let latPull = candidate(
            "Lat Pulldown", pattern: "vertical pull",
            primary: ["lats"], secondary: ["biceps"], equipment: "cable"
        )

        let output = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: [latPull, upperBack, seededAlias]
        )

        #expect(Set(output.map(\.candidate.id)) == Set([seededAlias.id, upperBack.id, latPull.id]))
        #expect(output.first?.candidate.id == seededAlias.id)
    }

    @Test func secondaryMuscleCannotAdmitCandidateFromAnotherPrimaryRegion() {
        let target = candidate(
            "Low Pulley Row", pattern: "horizontal pull",
            primary: ["middle back"], secondary: ["biceps"]
        )
        let curl = candidate(
            "Barbell Curl", pattern: "elbow flexion",
            primary: ["biceps"], secondary: ["forearms"]
        )
        let bench = candidate(
            "Bench Press", pattern: "horizontal push",
            primary: ["chest"], secondary: ["triceps"]
        )

        #expect(ExerciseSwapSuggester.suggest(replacing: target, from: [curl, bench]).isEmpty)
    }

    @Test func bicepsReplacementStaysWithinBicepsPrimaryRegion() {
        let target = candidate("Preacher Curl", pattern: "elbow flexion", primary: ["biceps"])
        let hammerCurl = candidate("Hammer Curl", pattern: "elbow flexion", primary: ["biceps"])
        let row = candidate(
            "Cable Row", pattern: "horizontal pull",
            primary: ["middle back"], secondary: ["biceps"]
        )

        let output = ExerciseSwapSuggester.suggest(replacing: target, from: [row, hammerCurl])

        #expect(output.map(\.candidate.id) == [hammerCurl.id])
    }

    @Test func completedWorkoutCountRanksFavoritesBeforeCloserUnusedMatches() {
        let target = candidate(
            "Low Pulley Row", pattern: "horizontal pull",
            primary: ["middle back"], secondary: ["lats", "biceps"]
        )
        let exactUnused = candidate(
            "Exact Cable Row", pattern: "horizontal pull",
            primary: ["middle back"], secondary: ["lats", "biceps"]
        )
        let favorite = candidate(
            "Favorite Pulldown", pattern: "vertical pull",
            primary: ["lats"], secondary: ["biceps"]
        )

        let output = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: [exactUnused, favorite],
            usageByID: [favorite.id: .init(completedWorkoutCount: 12)]
        )

        #expect(output.first?.candidate.id == favorite.id)
        #expect(output.first?.facets.contains(.usage(completedWorkoutCount: 12)) == true)
    }

    @Test func similarityBreaksEqualFavoriteCounts() {
        let target = candidate(
            "Low Pulley Row", pattern: "horizontal pull", primary: ["middle back"]
        )
        let exact = candidate(
            "Exact Row", pattern: "horizontal pull", primary: ["mid_back"]
        )
        let related = candidate(
            "Related Pulldown", pattern: "vertical pull", primary: ["lats"]
        )
        let usage = ExerciseSwapSuggester.UsageProfile(completedWorkoutCount: 5)

        let output = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: [related, exact],
            usageByID: [exact.id: usage, related.id: usage]
        )

        #expect(output.first?.candidate.id == exact.id)
    }

    @Test func strictEquipmentFiltersNeverLeakOtherCategories() {
        let target = candidate("Lat Pulldown", primary: ["lats"], equipment: "cable")
        let dumbbell = candidate("Dumbbell Row", primary: ["middle back"], equipment: "dumbbell")
        let machine = candidate("Machine Row", primary: ["upper back"], equipment: "machine")
        let bodyweight = candidate(
            "Pull-Up", primary: ["lats"], equipment: "body only", weightMode: .bodyweight
        )
        let assisted = candidate(
            "Assisted Pull-Up", primary: ["lats"], equipment: "machine",
            weightMode: .bodyweightAssisted
        )
        let pool = [dumbbell, machine, bodyweight, assisted]

        #expect(
            ExerciseSwapSuggester.suggest(
                replacing: target, from: pool, equipmentFilter: .freeWeights
            ).map(\.candidate.id) == [dumbbell.id]
        )
        #expect(
            Set(ExerciseSwapSuggester.suggest(
                replacing: target, from: pool, equipmentFilter: .machineOrCable
            ).map(\.candidate.id)) == Set([machine.id, assisted.id])
        )
        #expect(
            ExerciseSwapSuggester.suggest(
                replacing: target, from: pool, equipmentFilter: .bodyweight
            ).map(\.candidate.id) == [bodyweight.id]
        )
    }

    @Test func availableFiltersOnlyIncludeCategoriesWithEligibleCandidates() {
        let target = candidate("Chest Press", primary: ["chest"], equipment: "machine")
        let dumbbell = candidate("Dumbbell Bench Press", primary: ["chest"], equipment: "dumbbell")
        let unrelatedBodyweight = candidate(
            "Air Squat", primary: ["quadriceps"], equipment: "body only", weightMode: .bodyweight
        )

        let filters = ExerciseSwapSuggester.availableFilters(
            replacing: target,
            from: [dumbbell, unrelatedBodyweight]
        )

        #expect(filters == [.freeWeights])
    }

    @Test func excludesSelfInUseAndHonorsLimit() {
        let target = candidate("Squat", primary: ["quadriceps"], equipment: "barbell")
        let pool = (1...10).map {
            candidate("Quad Exercise \($0)", primary: ["quadriceps"], equipment: "dumbbell")
        }

        let output = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: pool + [target],
            excluding: [pool[0].id],
            limit: 3
        )

        #expect(output.count == 3)
        #expect(!output.map(\.candidate.id).contains(target.id))
        #expect(!output.map(\.candidate.id).contains(pool[0].id))
    }

    @Test func noPrimaryMusclesYieldsNoSuggestions() {
        let target = candidate("Mystery Movement", primary: [])
        let pool = [candidate("Barbell Bench Press", primary: ["chest"])]

        #expect(ExerciseSwapSuggester.suggest(replacing: target, from: pool).isEmpty)
    }

    @Test func knownMovementFamilyMismatchIsExcluded() {
        let target = candidate("Shoulder Press", pattern: "vertical push", primary: ["shoulders"])
        let wrongFamily = candidate("Shoulder Row", pattern: "horizontal pull", primary: ["shoulders"])

        #expect(ExerciseSwapSuggester.suggest(replacing: target, from: [wrongFamily]).isEmpty)
    }

    @Test func forceDoesNotDoubleCountTheSameMovementPattern() {
        let target = candidate("Target", pattern: "push", primary: ["chest"], force: "push")
        let duplicated = candidate("Duplicated", pattern: "push", primary: ["chest"], force: "push")
        let patternOnly = candidate("Pattern Only", pattern: "push", primary: ["chest"])

        let output = ExerciseSwapSuggester.suggest(
            replacing: target,
            from: [duplicated, patternOnly]
        )
        let scores = Dictionary(uniqueKeysWithValues: output.map { ($0.candidate.id, $0.score) })

        #expect(scores[duplicated.id] == scores[patternOnly.id])
    }
}
