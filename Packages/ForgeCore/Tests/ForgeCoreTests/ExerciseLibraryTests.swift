import XCTest
@testable import ForgeCore

final class ExerciseLibraryTests: XCTestCase {

    func testAliasAndTypoTolerantSearchFindsSeededExercise() throws {
        let exactAlias = try XCTUnwrap(GlobalExerciseLibrary.snapshot.search("RDL").first)
        XCTAssertEqual(exactAlias.exercise.id, GlobalExerciseLibrary.romanianDeadliftID)

        let typoAlias = try XCTUnwrap(GlobalExerciseLibrary.snapshot.search("bayseian curl").first)
        XCTAssertEqual(typoAlias.exercise.id, GlobalExerciseLibrary.bayesianCableCurlID)
    }

    func testSeedIncludesRequestedMachineAndCableVariants() {
        let names = Set(GlobalExerciseLibrary.snapshot.exercises.map(\.name))
        XCTAssertTrue(names.contains("Bayesian Cable Curl"))
        XCTAssertTrue(names.contains("Overhead Cable Triceps Extension"))
        XCTAssertTrue(names.contains("Chest-Supported T-Bar Row"))
        XCTAssertTrue(names.contains("Smith Machine Squat"))
        XCTAssertTrue(names.contains("Machine Chest Press"))
    }

    func testCustomExerciseMapsToGlobalTaxonomyForAnalytics() {
        let custom = ExerciseInfo(
            name: "Garage Row Handle",
            mappedGlobalID: GlobalExerciseLibrary.chestSupportedTBarRowID
        )
        let resolved = GlobalExerciseLibrary.snapshot.analyticsInfo(for: custom)
        let set = SetEntry(reps: 10, weight: 80)
        let volume = MuscleVolume.fractionalSets(for: set, exercise: resolved)

        XCTAssertEqual(resolved.movementPattern, "horizontal_pull")
        XCTAssertEqual(volume["lats"] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(volume["mid_back"] ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(volume["biceps"] ?? 0, 0.5, accuracy: 0.0001)
    }

    func testSetupNoteLookupReturnsExerciseLoadCue() throws {
        let userID = UUID()
        let note = ExerciseSetupNote(
            userID: userID,
            exerciseID: GlobalExerciseLibrary.machineChestPressID,
            note: "Use neutral handles when shoulder is cranky.",
            seatHeight: "4",
            grip: "neutral",
            painFlag: true
        )
        let snapshot = ExerciseLibrarySnapshot(
            exercises: GlobalExerciseLibrary.snapshot.exercises,
            aliases: GlobalExerciseLibrary.snapshot.aliases,
            setupNotes: [note]
        )

        let loadedNote = try XCTUnwrap(
            snapshot.setupNote(for: GlobalExerciseLibrary.machineChestPressID, userID: userID)
        )
        XCTAssertEqual(loadedNote.seatHeight, "4")
        XCTAssertEqual(loadedNote.grip, "neutral")
        XCTAssertTrue(loadedNote.painFlag)
    }
}
