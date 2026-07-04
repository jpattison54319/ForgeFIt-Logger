import XCTest
@testable import ForgeCore

/// Golden vectors for VolumeMath. These mirror the acceptance criteria in
/// docs/07-starter-implementation.md (AC-3…AC-6) and lock the math contract.
/// `ForgeCore` is the single source of truth — no server math to diverge from.
final class VolumeMathTests: XCTestCase {

    private let tol = 0.0001

    // AC-3: unilateral 30kg dumbbell × 10 reps × 2 arms = 600 total volume,
    // entered as a single 30kg implement weight.
    func testUnilateralTonnage() {
        let s = SetEntry(reps: 10, isUnilateral: true, implementWeight: 30, limbCount: 2)
        XCTAssertEqual(VolumeMath.effectiveLoad(s), 30, accuracy: tol)
        XCTAssertEqual(VolumeMath.tonnage(s), 600, accuracy: tol)
    }

    // Bilateral external load: 100kg × 5 = 500.
    func testBilateralTonnage() {
        let s = SetEntry(reps: 5, weight: 100)
        XCTAssertEqual(VolumeMath.tonnage(s), 500, accuracy: tol)
    }

    // AC-4: weighted pullup — BW 80 + added 20, 5 reps → effective 100, vol 500.
    func testWeightedBodyweight() {
        let s = SetEntry(weightMode: .bodyweightAdded, reps: 5, addedWeight: 20, bodyweightKg: 80)
        XCTAssertEqual(VolumeMath.effectiveLoad(s), 100, accuracy: tol)
        XCTAssertEqual(VolumeMath.tonnage(s), 500, accuracy: tol)
    }

    // AC-5: assisted dip — BW 80 − assist 30, 8 reps → effective 50, vol 400.
    func testAssistedBodyweight() {
        let s = SetEntry(weightMode: .bodyweightAssisted, reps: 8, assistanceWeight: 30, bodyweightKg: 80)
        XCTAssertEqual(VolumeMath.effectiveLoad(s), 50, accuracy: tol)
        XCTAssertEqual(VolumeMath.tonnage(s), 400, accuracy: tol)
    }

    // Assistance can't drive effective load below zero.
    func testAssistanceClampsAtZero() {
        let s = SetEntry(weightMode: .bodyweightAssisted, reps: 5, assistanceWeight: 200, bodyweightKg: 80)
        XCTAssertEqual(VolumeMath.effectiveLoad(s), 0, accuracy: tol)
        XCTAssertEqual(VolumeMath.tonnage(s), 0, accuracy: tol)
    }

    // Partial reps are half-weighted: 100kg, 5 full + 4 partials → 7 eff reps → 700.
    func testPartialReps() {
        let s = SetEntry(reps: 5, weight: 100, partialReps: 4)
        XCTAssertEqual(VolumeMath.effectiveReps(s), 7, accuracy: tol)
        XCTAssertEqual(VolumeMath.tonnage(s), 700, accuracy: tol)
    }

    // Warm-up sets contribute zero tonnage.
    func testWarmupCountsZero() {
        let s = SetEntry(setType: .warmup, reps: 10, weight: 60)
        XCTAssertEqual(VolumeMath.tonnage(s), 0, accuracy: tol)
    }

    // AC-6: Epley e1RM(100 × 5) ≈ 116.667.
    func testEpley1RM() throws {
        let s = SetEntry(reps: 5, weight: 100)
        let e1rm = try XCTUnwrap(VolumeMath.estimated1RM(s))
        XCTAssertEqual(e1rm, 116.6667, accuracy: 0.001)
    }

    func testE1RMNilWithoutReps() {
        let s = SetEntry(weight: 100)
        XCTAssertNil(VolumeMath.estimated1RM(s))
    }
}
