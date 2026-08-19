import ForgeCore
import ForgeData
import Foundation

/// Resolves frozen conditioning snapshots back to their editable preset. New
/// plans use `presetReferenceID`; legacy plans fall back to exact work and then
/// lineage matching so included-preset ordering changes do not orphan history.
enum ConditioningPresetResolver {
    static func selection(
        for section: ConditioningSection,
        records: [IntervalPresetModel],
        exercises: [ExerciseLibraryModel]
    ) -> ConditioningPresetSelection? {
        let saved = ConditioningPresetStore.savedPresets(from: records)
        let builtIns = ConditioningPreset.allCases.compactMap { preset -> ConditioningPresetSelection? in
            let selection = ConditioningPresetSelection.builtIn(preset)
            return selection.resolvedSection(in: exercises) == nil ? nil : selection
        }
        let candidates = saved + builtIns

        if let referenceID = section.presetReferenceID,
           let referenced = candidates.first(where: { $0.id == referenceID }) {
            return referenced
        }

        let exactKey = ConditioningPrescriptionSignature.key(for: section)
        let lineageKey = ConditioningPresetLineageSignature.key(for: section)
        let matches = candidates.compactMap { selection -> Match? in
            guard let candidateSection = selection.resolvedSection(in: exercises) else { return nil }
            let isExact = ConditioningPrescriptionSignature.key(for: candidateSection) == exactKey
            let isLineage = ConditioningPresetLineageSignature.key(for: candidateSection) == lineageKey
            guard isExact || isLineage else { return nil }
            return Match(selection: selection, exact: isExact)
        }

        let normalizedName = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let namedSaved = matches.first(where: {
            $0.selection.isSaved && $0.selection.title.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            return namedSaved.selection
        }
        let hiddenBuiltInIDs = ConditioningPresetStore.hiddenBuiltInIDs(from: records)
        let savedMatches = matches.filter(\.selection.isSaved)
        let hiddenBuiltInMatches = matches.contains { match in
            guard case .builtIn(let preset) = match.selection else { return false }
            return hiddenBuiltInIDs.contains(preset.id)
        }
        if hiddenBuiltInMatches, savedMatches.count == 1 {
            return savedMatches[0].selection
        }

        if let named = matches.first(where: {
            $0.selection.title.caseInsensitiveCompare(normalizedName) == .orderedSame
        }) {
            return named.selection
        }

        let exactMatches = matches.filter(\.exact)
        if exactMatches.count == 1 { return exactMatches[0].selection }
        if matches.count == 1 { return matches[0].selection }
        return nil
    }

    private struct Match {
        let selection: ConditioningPresetSelection
        let exact: Bool
    }
}

private extension ConditioningPresetSelection {
    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}
