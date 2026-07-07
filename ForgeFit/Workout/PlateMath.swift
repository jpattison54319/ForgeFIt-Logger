import ForgeCore
import Foundation

/// Pure barbell-loading math. Everything internal is kilograms (the data
/// layer's unit); the UI converts for display via `Fmt`/`WeightUnit`.
nonisolated struct PlateInventory: Codable, Equatable {
    struct PlateCount: Codable, Equatable, Identifiable {
        /// One plate's weight in the inventory's display unit.
        var weight: Double
        /// How many PAIRS the user owns (a pair loads one plate per side).
        var pairs: Int
        var id: Double { weight }
    }

    /// Bar weight in the inventory's display unit.
    var barWeight: Double
    var plates: [PlateCount]
    var unit: WeightUnit

    var barKg: Double { unit.kilograms(fromDisplayValue: barWeight) }

    /// Default gym setups per unit — editable in Settings.
    static func standard(unit: WeightUnit) -> PlateInventory {
        switch unit {
        case .lb:
            PlateInventory(
                barWeight: 45,
                plates: [45, 35, 25, 10, 5, 2.5].map { PlateCount(weight: $0, pairs: 8) },
                unit: .lb
            )
        case .kg:
            PlateInventory(
                barWeight: 20,
                plates: [25, 20, 15, 10, 5, 2.5, 1.25].map { PlateCount(weight: $0, pairs: 8) },
                unit: .kg
            )
        }
    }

    /// Common bar options for the picker, in the inventory's unit.
    static func barOptions(unit: WeightUnit) -> [(label: String, weight: Double)] {
        switch unit {
        case .lb: [("Olympic 45", 45), ("Women's 35", 35), ("EZ curl 25", 25), ("Trap 55", 55)]
        case .kg: [("Olympic 20", 20), ("Women's 15", 15), ("EZ curl 10", 10), ("Trap 25", 25)]
        }
    }
}

struct PlateSolution: Equatable {
    /// Plates for ONE side, heaviest first (display unit → count per side).
    var perSide: [(weight: Double, count: Int)]
    /// Total achievable weight in kg (bar + both sides).
    var achievedKg: Double
    /// True when the target was loadable exactly.
    var exact: Bool

    static func == (lhs: PlateSolution, rhs: PlateSolution) -> Bool {
        lhs.achievedKg == rhs.achievedKg && lhs.exact == rhs.exact
            && lhs.perSide.map(\.weight) == rhs.perSide.map(\.weight)
            && lhs.perSide.map(\.count) == rhs.perSide.map(\.count)
    }

    /// Greedy per-side loadout for `targetKg`, honoring pair counts. When the
    /// exact target isn't loadable, returns the closest loadable weight
    /// (preferring the nearest; ties go under, never over by more).
    static func solve(targetKg: Double, inventory: PlateInventory) -> PlateSolution {
        let unit = inventory.unit
        let barKg = inventory.barKg
        let perSideTargetKg = max(0, (targetKg - barKg) / 2)
        let perSideTarget = unit.displayValue(fromKilograms: perSideTargetKg)

        // Greedy under-fill: heaviest plates first without exceeding target.
        let available = inventory.plates
            .filter { $0.pairs > 0 && $0.weight > 0 }
            .sorted { $0.weight > $1.weight }
        var remaining = perSideTarget
        var loadout: [(weight: Double, count: Int)] = []
        for plate in available {
            let byWeight = Int((remaining / plate.weight) + 1e-9)
            let count = min(byWeight, plate.pairs)
            if count > 0 {
                loadout.append((plate.weight, count))
                remaining -= Double(count) * plate.weight
            }
        }

        let underPerSide = loadout.reduce(0.0) { $0 + $1.weight * Double($1.count) }
        let underKg = barKg + unit.kilograms(fromDisplayValue: underPerSide) * 2

        // If exact (within half the smallest increment), done.
        let epsilonKg = 0.01
        if abs(underKg - targetKg) < epsilonKg {
            return PlateSolution(perSide: loadout, achievedKg: targetKg, exact: true)
        }

        // Try one step over: add the smallest plate that closes the gap.
        var overLoadout: [(weight: Double, count: Int)]?
        for plate in available.reversed() {
            let used = loadout.first { $0.weight == plate.weight }?.count ?? 0
            if used < plate.pairs {
                var candidate = loadout
                if let index = candidate.firstIndex(where: { $0.weight == plate.weight }) {
                    candidate[index].count += 1
                } else {
                    candidate.append((plate.weight, 1))
                    candidate.sort { $0.weight > $1.weight }
                }
                overLoadout = candidate
                break
            }
        }

        if let overLoadout {
            let overPerSide = overLoadout.reduce(0.0) { $0 + $1.weight * Double($1.count) }
            let overKg = barKg + unit.kilograms(fromDisplayValue: overPerSide) * 2
            // Prefer whichever is nearer; ties go under.
            if abs(overKg - targetKg) < abs(underKg - targetKg) - epsilonKg {
                return PlateSolution(perSide: overLoadout, achievedKg: overKg, exact: false)
            }
        }
        return PlateSolution(perSide: loadout, achievedKg: underKg, exact: false)
    }
}

/// Persistence for the user's plate setup (`@AppStorage`-backed JSON, one per
/// unit so switching units keeps both gyms).
enum PlateInventoryStore {
    static func key(for unit: WeightUnit) -> String { "plateInventory.\(unit.rawValue)" }

    static func load(unit: WeightUnit) -> PlateInventory {
        guard let data = UserDefaults.standard.data(forKey: key(for: unit)),
              let inventory = try? JSONDecoder().decode(PlateInventory.self, from: data) else {
            return .standard(unit: unit)
        }
        return inventory
    }

    static func save(_ inventory: PlateInventory) {
        guard let data = try? JSONEncoder().encode(inventory) else { return }
        UserDefaults.standard.set(data, forKey: key(for: inventory.unit))
    }
}
