import XCTest
@testable import ForgeCore

/// Golden vectors for fractional-set muscle volume:
/// primary = 1.0 set, secondary = 0.5 set, warm-ups = 0.
final class MuscleVolumeTests: XCTestCase {

    private let tol = 0.0001

    private let benchPress = ExerciseInfo(
        name: "Barbell Bench Press",
        movementPattern: "horizontal_push",
        primaryMuscles: ["chest"],
        secondaryMuscles: ["triceps", "front_delts"]
    )

    // One working set: chest 1.0, triceps 0.5, front_delts 0.5.
    func testSingleSetFractionalSets() {
        let set = SetEntry(reps: 8, weight: 80)
        let v = MuscleVolume.fractionalSets(for: set, exercise: benchPress)
        XCTAssertEqual(v["chest"] ?? 0, 1.0, accuracy: tol)
        XCTAssertEqual(v["triceps"] ?? 0, 0.5, accuracy: tol)
        XCTAssertEqual(v["front_delts"] ?? 0, 0.5, accuracy: tol)
    }

    // Warm-up sets contribute no muscle volume.
    func testWarmupNoVolume() {
        let set = SetEntry(setType: .warmup, reps: 10, weight: 40)
        XCTAssertTrue(MuscleVolume.fractionalSets(for: set, exercise: benchPress).isEmpty)
    }

    // A muscle listed as both primary and secondary counts once, as primary.
    func testNoDoubleCounting() {
        let ex = ExerciseInfo(
            name: "Weird Hybrid",
            primaryMuscles: ["chest"],
            secondaryMuscles: ["chest", "triceps"]
        )
        let v = MuscleVolume.fractionalSets(for: SetEntry(reps: 8, weight: 50), exercise: ex)
        XCTAssertEqual(v["chest"] ?? 0, 1.0, accuracy: tol)   // primary wins, not 1.5
        XCTAssertEqual(v["triceps"] ?? 0, 0.5, accuracy: tol)
    }

    // Weekly aggregation across working sets, mixing exercises and a warm-up.
    func testWeeklyAggregation() {
        let incline = ExerciseInfo(
            name: "Incline DB Press",
            primaryMuscles: ["chest"],
            secondaryMuscles: ["triceps", "front_delts"]
        )
        let entries: [(set: SetEntry, exercise: ExerciseInfo)] = [
            (SetEntry(reps: 8, weight: 80), benchPress),                 // chest 1, tri .5, fd .5
            (SetEntry(reps: 8, weight: 80), benchPress),                 // chest 1, tri .5, fd .5
            (SetEntry(setType: .warmup, reps: 10, weight: 40), incline), // 0
            (SetEntry(reps: 10, weight: 30, isUnilateral: true,
                      implementWeight: 30), incline)                     // chest 1, tri .5, fd .5
        ]
        let totals = MuscleVolume.weeklyVolume(entries)
        XCTAssertEqual(totals["chest"] ?? 0, 3.0, accuracy: tol)
        XCTAssertEqual(totals["triceps"] ?? 0, 1.5, accuracy: tol)
        XCTAssertEqual(totals["front_delts"] ?? 0, 1.5, accuracy: tol)
    }
}
