import ForgeCore
import ForgeData
import Foundation

enum ConditioningPresetSelection: Identifiable, Equatable {
    case builtIn(ConditioningPreset)
    case saved(id: UUID, name: String, section: ConditioningSection)

    var id: String {
        switch self {
        case .builtIn(let preset):
            "built-in-\(preset.id)"
        case .saved(let id, _, _):
            "saved-\(id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .builtIn(let preset): preset.title
        case .saved(_, let name, _): name
        }
    }

    var menuTitle: String {
        switch self {
        case .builtIn(let preset): preset.menuTitle
        case .saved(_, let name, let section): "\(name) · \(section.presetSummary)"
        }
    }

    var detail: String {
        switch self {
        case .builtIn(let preset): preset.summary
        case .saved(_, _, let section): section.presetSummary
        }
    }

    /// Resolves an included preset through the live exercise catalog while a
    /// saved preset already carries its frozen prescription.
    func resolvedSection(in catalog: [ExerciseLibraryModel]) -> ConditioningSection? {
        switch self {
        case .saved(_, _, var section):
            section.presetReferenceID = id
            return section
        case .builtIn(let preset):
            let catalogByName = Dictionary(
                catalog.lazy
                    .filter { $0.deletedAt == nil }
                    .map { ($0.name.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolvedIDs = preset.movements.compactMap {
                catalogByName[$0.catalogName.lowercased()]?.id
            }
            guard resolvedIDs.count == preset.movements.count else { return nil }
            return preset.makeSection(exerciseIDs: resolvedIDs)
        }
    }
}

private extension ConditioningSection {
    var presetSummary: String {
        let movementLabel = movements.count == 1 ? "1 movement" : "\(movements.count) movements"

        switch format {
        case .amrap:
            if let durationSeconds {
                return "\(max(1, durationSeconds / 60)) min AMRAP · \(movementLabel)"
            }
        case .forTime:
            if let prescribedRounds {
                return "\(prescribedRounds) rounds for time · \(movementLabel)"
            }
        case .emom:
            if let rounds {
                return "\(rounds)-minute EMOM · \(movementLabel)"
            }
        case .intervals:
            if let rounds {
                return "\(rounds) intervals · \(movementLabel)"
            }
        case .ladder:
            if !repScheme.isEmpty {
                return "\(repScheme.map(String.init).joined(separator: "–")) ladder · \(movementLabel)"
            }
        case .maxLoad:
            if let rounds {
                return "\(rounds) attempts for load · \(movementLabel)"
            }
        }

        return "\(format.title) · \(movementLabel)"
    }
}
