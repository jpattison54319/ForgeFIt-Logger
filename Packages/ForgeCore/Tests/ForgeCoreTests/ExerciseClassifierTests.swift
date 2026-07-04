import XCTest
@testable import ForgeCore

final class ExerciseClassifierTests: XCTestCase {
    private let seedCorpus = [
        ExerciseInfo(
            name: "Machine Chest Press",
            movementPattern: "horizontal_push",
            primaryMuscles: ["chest"],
            secondaryMuscles: ["triceps", "shoulders"],
            equipment: "machine"
        ),
        ExerciseInfo(
            name: "Cable Hip Abduction",
            movementPattern: "abduction",
            primaryMuscles: ["abductors"],
            secondaryMuscles: ["glutes"],
            equipment: "cable"
        )
    ]

    func testKeywordClassifiesCommonStrengthLifts() {
        let classifier = ExerciseClassifier(seedCorpus: seedCorpus)

        XCTAssertEqual(classifier.classify(name: "Dumbbell Curl").primaryMuscles, ["biceps"])
        XCTAssertEqual(classifier.classify(name: "Bench Press").primaryMuscles, ["chest"])
        XCTAssertEqual(classifier.classify(name: "Back Squat").primaryMuscles, ["quadriceps", "glutes"])
        XCTAssertEqual(classifier.classify(name: "Romanian Deadlift").primaryMuscles, ["hamstrings", "glutes"])
        XCTAssertEqual(classifier.classify(name: "Cable Lateral Raise").primaryMuscles, ["shoulders"])
    }

    func testCardioDetectionUsesNameAndMetricsHint() {
        let classifier = ExerciseClassifier(seedCorpus: seedCorpus)

        let treadmill = classifier.classify(name: "Treadmill Run")
        XCTAssertTrue(treadmill.isCardio)
        XCTAssertEqual(treadmill.primaryMuscles.first, "cardiovascular")

        let distanceOnly = classifier.classify(
            name: "Conditioning",
            hint: ExerciseClassificationHint(hasDistance: true, hasReps: false, hasWeight: false)
        )
        XCTAssertTrue(distanceOnly.isCardio)
        XCTAssertLessThan(distanceOnly.confidence, ExerciseClassifier.reviewConfidenceThreshold)
    }

    func testSeedFuzzyBorrowsMusclesForNonKeywordMatch() {
        let classifier = ExerciseClassifier(seedCorpus: seedCorpus)

        let result = classifier.classify(name: "Cable Hip Abducton")

        XCTAssertEqual(result.source, .seedFuzzy)
        XCTAssertEqual(result.primaryMuscles, ["abductors"])
        XCTAssertEqual(result.secondaryMuscles, ["glutes"])
    }

    func testFallbackStaysFlaggable() {
        let classifier = ExerciseClassifier(seedCorpus: seedCorpus)

        let result = classifier.classify(name: "Mystery Thing")

        XCTAssertEqual(result.source, .fallback)
        XCTAssertTrue(result.primaryMuscles.isEmpty)
        XCTAssertLessThan(result.confidence, ExerciseClassifier.reviewConfidenceThreshold)
    }
}
