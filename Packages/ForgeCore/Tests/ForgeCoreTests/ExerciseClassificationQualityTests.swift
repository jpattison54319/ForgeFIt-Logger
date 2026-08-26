import Testing
@testable import ForgeCore

struct ExerciseClassificationQualityTests {
    private let classifier = ExerciseClassifier(seedCorpus: [])

    @Test func clearImportedNamesUseConservativeMuscleRules() {
        let latPrayer = classifier.classify(name: "Lat Prayer")
        #expect(latPrayer.primaryMuscles == ["lats"])
        #expect(latPrayer.secondaryMuscles.isEmpty)
        #expect(latPrayer.source == .keyword)

        let abduction = classifier.classify(name: "Lean Back Abduction Machine")
        #expect(abduction.primaryMuscles == ["abductors"])
        #expect(abduction.secondaryMuscles == ["glutes"])
        #expect(abduction.equipment == "machine")

        let adduction = classifier.classify(name: "Hip Adduction (Machine)")
        #expect(adduction.primaryMuscles == ["adductors"])
        #expect(adduction.secondaryMuscles.isEmpty)

        let jeffersonCurl = classifier.classify(name: "Seated Zercher Jefferson Curl")
        #expect(jeffersonCurl.primaryMuscles == ["lower back", "hamstrings"])
        #expect(jeffersonCurl.secondaryMuscles == ["glutes"])

        let wristExtension = classifier.classify(name: "Barbell Wrist Extensions")
        #expect(wristExtension.primaryMuscles == ["forearms"])
    }

    @Test func importedShoulderAndChestNamesUseRefinedTaxonomy() {
        #expect(classifier.classify(name: "Cable Rear Delt Fly").primaryMuscles == ["rear delts"])
        #expect(classifier.classify(name: "Cable Lateral Raise").primaryMuscles == ["side delts"])
        #expect(classifier.classify(name: "Incline Chest Press (Machine)").primaryMuscles == ["upper chest"])
        #expect(classifier.classify(name: "Decline Push Up").primaryMuscles == ["upper chest"])
    }

    @Test func keywordMatchingDoesNotTreatSubstringsAsMovements() {
        let throwing = classifier.classify(name: "Throwing Drill")
        let curling = classifier.classify(name: "Curling Practice")

        #expect(throwing.source == .fallback)
        #expect(throwing.primaryMuscles.isEmpty)
        #expect(curling.source == .fallback)
        #expect(curling.primaryMuscles.isEmpty)
    }
}
