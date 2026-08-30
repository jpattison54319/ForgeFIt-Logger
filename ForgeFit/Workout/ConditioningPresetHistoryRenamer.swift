import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Shared exact-preset matcher for analytics lookup and history rewriting.
/// Matching plan snapshots does not require a result payload: a completed
/// workout can still carry authored preset history that must follow a rename.
nonisolated struct ConditioningPresetHistoryMatcher: Sendable {
    private let prescriptionKey: String
    private let lineageKey: String
    private let sourceReferenceID: String?

    init(source: ConditioningSection) {
        prescriptionKey = ConditioningPrescriptionSignature.key(for: source)
        lineageKey = ConditioningPresetLineageSignature.key(for: source)
        sourceReferenceID = source.presetReferenceID
    }

    func matches(_ section: ConditioningSection) -> Bool {
        let sameReference = sourceReferenceID != nil
            && section.presetReferenceID == sourceReferenceID
        let samePrescription = ConditioningPrescriptionSignature.key(for: section) == prescriptionKey
        let sameLineage = ConditioningPresetLineageSignature.key(for: section) == lineageKey
        return sameReference || samePrescription || sameLineage
    }

    func workoutContainsMatchingPlan(_ workout: WorkoutModel) -> Bool {
        if let plan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON),
           plan.sections.contains(where: matches) {
            return true
        }
        return workout.blocks.contains { block in
            guard block.kind == .conditioning,
                  let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) else {
                return false
            }
            return plan.sections.contains(where: matches)
        }
    }
}

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
        context: ModelContext,
        saveChanges: Bool = true
    ) throws {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let matcher = ConditioningPresetHistoryMatcher(source: source)
        let now = Date.now

        for workout in workouts where workout.deletedAt == nil && workout.endedAt != nil {
            var changedWorkout = false

            if let json = workout.conditioningPlanSnapshotJSON,
               var plan = ConditioningPlan.decode(from: json),
               renameSections(
                   in: &plan,
                   matching: matcher,
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
                          matching: matcher,
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

        if saveChanges { try context.save() }
    }

    private static func renameSections(
        in plan: inout ConditioningPlan,
        matching matcher: ConditioningPresetHistoryMatcher,
        to name: String,
        presetReferenceID: String
    ) -> Bool {
        var changed = false
        for index in plan.sections.indices {
            let section = plan.sections[index]
            guard matcher.matches(section) else { continue }
            guard section.name != name || section.presetReferenceID != presetReferenceID else { continue }
            plan.sections[index].name = name
            plan.sections[index].presetReferenceID = presetReferenceID
            changed = true
        }
        return changed
    }
}
