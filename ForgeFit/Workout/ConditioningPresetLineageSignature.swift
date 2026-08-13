import ForgeCore
import Foundation

/// Backward-compatible preset identity for plans saved before a stable preset
/// reference was embedded in snapshots. Movement rows are sorted because old
/// included-preset versions could emit the same work in a different order.
enum ConditioningPresetLineageSignature {
    static func key(for section: ConditioningSection) -> String {
        let movements = section.movements.map { movement in
            [
                movement.exerciseID.uuidString,
                String(movement.targetValue.bitPattern),
                movement.targetUnit.rawValue,
                movement.targetLoad.map { String($0.bitPattern) } ?? "nil",
                movement.weightMode.rawValue
            ].joined(separator: ":")
        }
        .sorted()
        .joined(separator: ";")
        let components: [String] = [
            section.format.rawValue,
            section.ordering.rawValue,
            section.scoreKind.rawValue,
            section.durationSeconds.map(String.init) ?? "nil",
            section.timeCapSeconds.map(String.init) ?? "nil",
            section.rounds.map(String.init) ?? "nil",
            section.intervalSeconds.map(String.init) ?? "nil",
            section.workSeconds.map(String.init) ?? "nil",
            section.restSeconds.map(String.init) ?? "nil",
            section.repScheme.map(String.init).joined(separator: ","),
            section.ladderStep.map(String.init) ?? "nil",
            String(section.endsOnFailure),
            String(section.restartEachInterval),
            movements
        ]
        return components.joined(separator: "|")
    }
}
