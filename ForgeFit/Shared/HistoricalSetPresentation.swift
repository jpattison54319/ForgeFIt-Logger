import ForgeCore
import ForgeData
import Foundation

/// Presentation helpers for history/share set rows.
///
/// Routine-seeded (ghost) targets live on `SetModel.weight`/`reps` even when
/// `completedAt` is nil. History must not present those as performed work, and
/// volume must only sum completed sets.
enum HistoricalSetPresentation {
    static let incompleteLabel = "Not done"

    static func isCompleted(_ set: SetModel) -> Bool {
        set.completedAt != nil
    }

    static func loadText(_ set: SetModel, unit: WeightUnit) -> String {
        guard isCompleted(set) else { return "—" }
        return Fmt.loadUnit(set.modeWeight, unit: unit)
    }

    static func outputText(_ set: SetModel) -> String {
        guard isCompleted(set) else { return incompleteLabel }
        if !set.miniReps.isEmpty {
            let activation = set.reps.map(String.init)
            let minis = set.miniReps.map(String.init).joined(separator: "+")
            return [activation, minis].compactMap(\.self).joined(separator: "+") + " reps"
        }
        // True AMRAP: reps achieved inside a fixed time window — show both,
        // since progression means more reps in the same window.
        if set.setType == .amrap, let reps = set.reps, let seconds = set.durationSeconds, seconds > 0 {
            return "\(reps) reps in \(seconds)s"
        }
        if let seconds = set.durationSeconds, seconds > 0 {
            return Fmt.durationShort(seconds)
        }
        return "\(set.reps.map(String.init) ?? "—") reps"
    }

    static func shareValue(_ set: SetModel, unit: WeightUnit) -> String {
        guard isCompleted(set) else { return incompleteLabel }
        if !set.miniReps.isEmpty {
            let activation = set.reps.map(String.init)
            let minis = set.miniReps.map(String.init).joined(separator: "+")
            let reps = [activation, minis].compactMap(\.self).joined(separator: "+")
            guard let weight = set.modeWeight, weight > 0 else { return "\(reps) reps" }
            return "\(Fmt.load(weight, unit: unit)) \(unit.suffix) × \(reps)"
        }
        if let seconds = set.durationSeconds, seconds > 0 {
            return Fmt.durationShort(seconds)
        }
        let reps = set.reps.map { "\($0)" } ?? "—"
        guard let weight = set.modeWeight, weight > 0 else { return "\(reps) reps" }
        return "\(Fmt.load(weight, unit: unit)) \(unit.suffix) × \(reps)"
    }

    /// Set-level tonnage only counts when the set was completed.
    static func tonnageContributingToVolume(_ set: SetModel) -> Double {
        guard isCompleted(set) else { return 0 }
        return set.totalVolume ?? 0
    }

    static func workoutVolume(from sets: [SetModel]) -> Double {
        sets.reduce(0) { $0 + tonnageContributingToVolume($1) }
    }
}
