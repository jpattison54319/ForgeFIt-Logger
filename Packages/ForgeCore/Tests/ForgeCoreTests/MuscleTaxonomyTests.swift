import Testing
@testable import ForgeCore

/// Parent/child muscle taxonomy + normalization of legacy string variants.
struct MuscleTaxonomyTests {
    @Test func shouldersBackChestHaveTheirSubMuscles() {
        #expect(MuscleTaxonomy.children["shoulders"] == ["front delts", "side delts", "rear delts"])
        #expect(MuscleTaxonomy.children["back"] == ["lats", "upper back", "middle back", "lower back", "traps"])
        #expect(MuscleTaxonomy.children["chest"] == ["upper chest", "mid chest", "lower chest"])
    }

    @Test func canonicalNormalizesLegacyVariants() {
        #expect(MuscleTaxonomy.canonical("front_delts") == "front delts")
        #expect(MuscleTaxonomy.canonical("mid_back") == "middle back")
        #expect(MuscleTaxonomy.canonical("spinal_erectors") == "lower back")
        #expect(MuscleTaxonomy.canonical("cardiorespiratory") == "cardiovascular")
        #expect(MuscleTaxonomy.canonical("Quads") == "quadriceps")
        #expect(MuscleTaxonomy.canonical("  Chest ") == "chest")
        // Unknown strings pass through instead of being dropped.
        #expect(MuscleTaxonomy.canonical("full body") == "full body")
    }

    @Test func parentRollsChildrenUpAndLeavesTopLevelAlone() {
        #expect(MuscleTaxonomy.parent(of: "rear delts") == "shoulders")
        #expect(MuscleTaxonomy.parent(of: "rear_delts") == "shoulders")
        #expect(MuscleTaxonomy.parent(of: "lats") == "back")
        #expect(MuscleTaxonomy.parent(of: "upper chest") == "chest")
        #expect(MuscleTaxonomy.parent(of: "biceps") == "biceps")
        #expect(MuscleTaxonomy.parent(of: "shoulders") == "shoulders")
    }

    @Test func matchesFindsChildrenUnderTheirGroup() {
        #expect(MuscleTaxonomy.matches("rear delts", group: "shoulders"))
        #expect(MuscleTaxonomy.matches("rear_delts", group: "Shoulders"))
        #expect(MuscleTaxonomy.matches("shoulders", group: "shoulders"))
        #expect(MuscleTaxonomy.matches("lats", group: "back"))
        #expect(!MuscleTaxonomy.matches("lats", group: "shoulders"))
        // A child filter is a specific ask — an exercise tagged with just the
        // broad parent doesn't claim that specific region.
        #expect(!MuscleTaxonomy.matches("back", group: "lats"))
    }

    @Test func displayNameCapitalizesEachWord() {
        #expect(MuscleTaxonomy.displayName("front_delts") == "Front Delts")
        #expect(MuscleTaxonomy.displayName("upper back") == "Upper Back")
        #expect(MuscleTaxonomy.displayName("chest") == "Chest")
    }

    /// The analytics rollup promise: legacy and canonical spellings of the
    /// same muscle land in one volume bucket.
    @Test func volumeBucketsMergeAcrossSpellings() {
        let old = ExerciseInfo(name: "OHP", primaryMuscles: ["front_delts"], secondaryMuscles: [])
        let new = ExerciseInfo(name: "Incline Press", primaryMuscles: ["front delts"], secondaryMuscles: [])
        let totals = MuscleVolume.weeklyVolume([
            (SetEntry(reps: 8, weight: 60), old),
            (SetEntry(reps: 8, weight: 60), new),
        ])
        #expect(totals.count == 1)
        #expect(totals["front delts"] == 2.0)
    }
}
