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

    // MARK: - Effective set count (documented convention — golden vectors)

    // Straight-set types are the literature's unit: exactly 1.
    func testEffectiveSetCountStraightTypes() {
        XCTAssertEqual(VolumeMath.effectiveSetCount(SetEntry(setType: .working)), 1, accuracy: tol)
        XCTAssertEqual(VolumeMath.effectiveSetCount(SetEntry(setType: .backoff)), 1, accuracy: tol)
        XCTAssertEqual(VolumeMath.effectiveSetCount(SetEntry(setType: .amrap)), 1, accuracy: tol)
        XCTAssertEqual(VolumeMath.effectiveSetCount(SetEntry(setType: .warmup)), 0, accuracy: tol)
    }

    // A drop row is half a set (Sødal et al. 2023: comparable hypertrophy in
    // roughly half the time — not a full set per drop).
    func testEffectiveSetCountDrop() {
        XCTAssertEqual(VolumeMath.effectiveSetCount(SetEntry(setType: .drop)), 0.5, accuracy: tol)
    }

    // The canonical myo-rep block: 6 + 3+3+2+2 = activation + 4 minis
    // = 3.0 sets ("≈3 sets in less time", Prestes et al. 2019).
    func testEffectiveSetCountMyoRepBlock() {
        let block = SetEntry(setType: .myoRep, reps: 6, miniSetCount: 4)
        XCTAssertEqual(VolumeMath.effectiveSetCount(block), 3.0, accuracy: tol)

        let restPause = SetEntry(setType: .restPause, reps: 8, miniSetCount: 2)
        XCTAssertEqual(VolumeMath.effectiveSetCount(restPause), 2.0, accuracy: tol)

        // No minis logged yet: the activation alone is one set.
        let bare = SetEntry(setType: .myoRep, reps: 6)
        XCTAssertEqual(VolumeMath.effectiveSetCount(bare), 1.0, accuracy: tol)
    }

    // Cluster segments are ONE set by design (Tufano et al. 2017) — the
    // segment count never inflates it.
    func testEffectiveSetCountCluster() {
        let cluster = SetEntry(setType: .cluster, reps: 10, miniSetCount: 5)
        XCTAssertEqual(VolumeMath.effectiveSetCount(cluster), 1.0, accuracy: tol)
    }

    // Unilateral per-side logging doubles the structure: each side is its own
    // activation + minis (or its own cluster).
    func testEffectiveSetCountPerSide() {
        let myoBothSides = SetEntry(setType: .myoRep, reps: 6, miniSetCount: 4, side2Logged: true, side2MiniSetCount: 3)
        XCTAssertEqual(VolumeMath.effectiveSetCount(myoBothSides), 5.5, accuracy: tol) // 3.0 + 2.5

        let clusterBothSides = SetEntry(setType: .cluster, reps: 10, miniSetCount: 5, side2Logged: true, side2MiniSetCount: 4)
        XCTAssertEqual(VolumeMath.effectiveSetCount(clusterBothSides), 2.0, accuracy: tol)
    }
}
