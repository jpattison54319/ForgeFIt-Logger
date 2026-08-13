import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Repairs legacy workout snapshots after a preset rename and stamps stable
/// identity for future lookups. It is idempotent and skips active workouts so
/// launch maintenance can never rewrite a live session underneath the logger.
@MainActor
enum ConditioningPresetHistoryReconciler {
    @discardableResult
    static func reconcile(
        records: [IntervalPresetModel],
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        context: ModelContext
    ) throws -> Int {
        let now = Date.now
        var changedRecords = 0
        var changedWorkouts = 0

        for record in records where record.deletedAt == nil {
            guard case .section(var section) = record.storedConditioningPreset else { continue }
            let referenceID = "saved-\(record.id.uuidString)"
            let trimmedName = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  section.name != trimmedName || section.presetReferenceID != referenceID else { continue }
            section.name = trimmedName
            section.presetReferenceID = referenceID
            guard let json = StoredConditioningPreset.section(section).encodedJSON() else { continue }
            record.planJSON = json
            record.updatedAt = now
            changedRecords += 1
        }

        for workout in workouts where workout.deletedAt == nil && workout.endedAt != nil {
            var changedWorkout = false

            if let json = workout.conditioningPlanSnapshotJSON,
               var plan = ConditioningPlan.decode(from: json),
               canonicalize(
                   plan: &plan,
                   records: records,
                   exercises: exercises
               ),
               let updatedJSON = plan.encodedJSON() {
                let oldName = ConditioningPlan.decode(from: json)?.sections.first?.name
                workout.conditioningPlanSnapshotJSON = updatedJSON
                updateWorkoutTitleIfNeeded(workout, oldName: oldName, plan: plan)
                changedWorkout = true
            }

            for block in workout.blocks where block.kind == .conditioning {
                guard let json = block.planSnapshotJSON,
                      var plan = ConditioningPlan.decode(from: json),
                      canonicalize(
                          plan: &plan,
                          records: records,
                          exercises: exercises
                      ),
                      let updatedJSON = plan.encodedJSON() else { continue }
                let oldName = ConditioningPlan.decode(from: json)?.sections.first?.name
                block.planSnapshotJSON = updatedJSON
                block.updatedAt = now
                updateWorkoutTitleIfNeeded(workout, oldName: oldName, plan: plan)
                changedWorkout = true
            }

            if changedWorkout {
                workout.updatedAt = now
                changedWorkouts += 1
            }
        }

        guard changedRecords + changedWorkouts > 0 else { return 0 }
        try context.save()
        return changedWorkouts
    }

    private static func canonicalize(
        plan: inout ConditioningPlan,
        records: [IntervalPresetModel],
        exercises: [ExerciseLibraryModel]
    ) -> Bool {
        var changed = false
        for index in plan.sections.indices {
            let section = plan.sections[index]
            guard let selection = ConditioningPresetResolver.selection(
                for: section,
                records: records,
                exercises: exercises
            ) else { continue }
            guard section.name != selection.title
                    || section.presetReferenceID != selection.id else { continue }
            plan.sections[index].name = selection.title
            plan.sections[index].presetReferenceID = selection.id
            changed = true
        }
        return changed
    }

    private static func updateWorkoutTitleIfNeeded(
        _ workout: WorkoutModel,
        oldName: String?,
        plan: ConditioningPlan
    ) {
        guard plan.sections.count == 1,
              let oldName,
              workout.title?.trimmingCharacters(in: .whitespacesAndNewlines) == oldName,
              let canonicalName = plan.sections.first?.name else { return }
        workout.title = canonicalName
    }
}
