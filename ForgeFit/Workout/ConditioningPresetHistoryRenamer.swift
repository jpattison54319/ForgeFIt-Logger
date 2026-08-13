import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Preset names are presentation metadata. Renaming one rewrites only frozen
/// workout plans with the same full prescription, leaving scores and progress
/// untouched and avoiding name-only matches against unrelated sessions.
@MainActor
enum ConditioningPresetHistoryRenamer {
    static func renameMatchingHistory(
        from source: ConditioningSection,
        to newName: String,
        presetReferenceID: String,
        in workouts: [WorkoutModel],
        context: ModelContext
    ) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let sourceKey = ConditioningPrescriptionSignature.key(for: source)
        let sourceLineageKey = ConditioningPresetLineageSignature.key(for: source)
        let now = Date.now

        for workout in workouts where workout.deletedAt == nil && workout.endedAt != nil {
            var changedWorkout = false

            if let json = workout.conditioningPlanSnapshotJSON,
               var plan = ConditioningPlan.decode(from: json),
               renameSections(
                   in: &plan,
                   matching: sourceKey,
                   lineageKey: sourceLineageKey,
                   sourceReferenceID: source.presetReferenceID,
                   to: trimmedName,
                   presetReferenceID: presetReferenceID
               ),
               let updatedJSON = plan.encodedJSON() {
                workout.conditioningPlanSnapshotJSON = updatedJSON
                changedWorkout = true
            }

            for block in workout.blocks where block.kind == .conditioning {
                guard let json = block.planSnapshotJSON,
                      var plan = ConditioningPlan.decode(from: json),
                      renameSections(
                          in: &plan,
                          matching: sourceKey,
                          lineageKey: sourceLineageKey,
                          sourceReferenceID: source.presetReferenceID,
                          to: trimmedName,
                          presetReferenceID: presetReferenceID
                      ),
                      let updatedJSON = plan.encodedJSON() else { continue }
                block.planSnapshotJSON = updatedJSON
                block.updatedAt = now
                changedWorkout = true
            }

            if changedWorkout,
               workout.title?.trimmingCharacters(in: .whitespacesAndNewlines) == source.name {
                workout.title = trimmedName
            }
            if changedWorkout { workout.updatedAt = now }
        }

        try context.save()
    }

    private static func renameSections(
        in plan: inout ConditioningPlan,
        matching sourceKey: String,
        lineageKey: String,
        sourceReferenceID: String?,
        to name: String,
        presetReferenceID: String
    ) -> Bool {
        var changed = false
        for index in plan.sections.indices {
            let section = plan.sections[index]
            let sameReference = sourceReferenceID != nil
                && section.presetReferenceID == sourceReferenceID
            let samePrescription = ConditioningPrescriptionSignature.key(for: section) == sourceKey
            let sameLineage = ConditioningPresetLineageSignature.key(for: section) == lineageKey
            guard sameReference || samePrescription || sameLineage else { continue }
            guard section.name != name || section.presetReferenceID != presetReferenceID else { continue }
            plan.sections[index].name = name
            plan.sections[index].presetReferenceID = presetReferenceID
            changed = true
        }
        return changed
    }
}
