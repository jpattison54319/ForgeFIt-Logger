import Testing
import Foundation
import ForgeCore
@testable import ForgeFit

/// Pure plate-loading math: exact loads, closest-loadable fallbacks, pair
/// limits, and unit round-trips.
struct PlateMathTests {

    private var lb: PlateInventory { .standard(unit: .lb) }
    private var kg: PlateInventory { .standard(unit: .kg) }

    private func kgFromLb(_ pounds: Double) -> Double {
        WeightUnit.lb.kilograms(fromDisplayValue: pounds)
    }

    @Test func exactLoadTwoPlates() {
        // 225 lb = 45 bar + 2×45 per side.
        let solution = PlateSolution.solve(targetKg: kgFromLb(225), inventory: lb)
        #expect(solution.exact)
        #expect(solution.perSide.count == 1)
        #expect(solution.perSide[0].weight == 45)
        #expect(solution.perSide[0].count == 2)
    }

    @Test func exactMixedLoad() {
        // 215 lb → 85/side; greedy takes the heaviest first: 45 + 35 + 5.
        let solution = PlateSolution.solve(targetKg: kgFromLb(215), inventory: lb)
        #expect(solution.exact)
        #expect(solution.perSide.map(\.weight) == [45, 35, 5])
        #expect(solution.perSide.map(\.count) == [1, 1, 1])
    }

    @Test func barOnly() {
        let solution = PlateSolution.solve(targetKg: kgFromLb(45), inventory: lb)
        #expect(solution.exact)
        #expect(solution.perSide.isEmpty)
    }

    @Test func belowBarClampsToBar() {
        let solution = PlateSolution.solve(targetKg: kgFromLb(20), inventory: lb)
        #expect(!solution.exact)
        #expect(solution.perSide.isEmpty)
        #expect(abs(solution.achievedKg - kgFromLb(45)) < 0.01)
    }

    @Test func unloadableTargetReturnsClosest() {
        // 226 lb isn't loadable with 2.5 lb smallest plates (steps of 5):
        // closest are 225 and 230 — 225 is nearer.
        let solution = PlateSolution.solve(targetKg: kgFromLb(226), inventory: lb)
        #expect(!solution.exact)
        #expect(abs(WeightUnit.lb.displayValue(fromKilograms: solution.achievedKg) - 225) < 0.01)
    }

    @Test func unloadableTargetPrefersNearerOver() {
        // 229 lb: closest under is 225 (off by 4), over is 230 (off by 1) → 230.
        let solution = PlateSolution.solve(targetKg: kgFromLb(229), inventory: lb)
        #expect(!solution.exact)
        #expect(abs(WeightUnit.lb.displayValue(fromKilograms: solution.achievedKg) - 230) < 0.01)
    }

    @Test func pairLimitsAreHonored() {
        var limited = lb
        limited.plates = [PlateInventory.PlateCount(weight: 45, pairs: 1), PlateInventory.PlateCount(weight: 25, pairs: 1)]
        // 225 lb wants 2×45/side but only 1 pair exists → 45+25 per side = 185.
        let solution = PlateSolution.solve(targetKg: kgFromLb(225), inventory: limited)
        #expect(!solution.exact)
        #expect(solution.perSide.map(\.weight) == [45, 25])
        #expect(abs(WeightUnit.lb.displayValue(fromKilograms: solution.achievedKg) - 185) < 0.01)
    }

    @Test func emptyInventoryIsJustTheBar() {
        var empty = lb
        empty.plates = []
        let solution = PlateSolution.solve(targetKg: kgFromLb(315), inventory: empty)
        #expect(!solution.exact)
        #expect(solution.perSide.isEmpty)
        #expect(abs(solution.achievedKg - kgFromLb(45)) < 0.01)
    }

    @Test func kilogramGymExactLoad() {
        // 100 kg = 20 bar + 40/side = 25 + 15 per side.
        let solution = PlateSolution.solve(targetKg: 100, inventory: kg)
        #expect(solution.exact)
        #expect(solution.perSide.map(\.weight) == [25, 15])
    }

    @Test func kilogramMicroPlates() {
        // 62.5 kg = 20 + 21.25/side = 20 + 1.25.
        let solution = PlateSolution.solve(targetKg: 62.5, inventory: kg)
        #expect(solution.exact)
        #expect(solution.perSide.map(\.weight) == [20, 1.25])
    }

    @Test func inventoryRoundTripsThroughJSON() throws {
        let original = PlateInventory.standard(unit: .kg)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlateInventory.self, from: data)
        #expect(decoded == original)
    }
}
