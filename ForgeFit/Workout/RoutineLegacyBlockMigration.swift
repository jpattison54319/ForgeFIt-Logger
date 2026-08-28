import ForgeCore
import ForgeData
import SwiftData

/// Converts the routine editor's legacy conditioning/Yoga representation into
/// first-class ordered blocks. This service owns only graph normalization: the
/// caller remains responsible for authored timestamps and persistence.
@MainActor
enum RoutineLegacyBlockMigration {
    /// - Returns: `true` only when a legacy field or exercise row was converted.
    @discardableResult
    static func migrateIfNeeded(
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        in modelContext: ModelContext
    ) -> Bool {
        var didChange = migrateConditioningIfNeeded(
            routine: routine,
            in: modelContext
        )

        if migrateYogaIfNeeded(
            routine: routine,
            exercises: exercises,
            in: modelContext
        ) {
            didChange = true
        }

        guard didChange else { return false }

        for (index, item) in OrderedRoutineItem.ordered(in: routine).enumerated()
        where item.position != index {
            item.position = index
        }
        return true
    }

    private static func migrateConditioningIfNeeded(
        routine: RoutineModel,
        in modelContext: ModelContext
    ) -> Bool {
        guard let conditioningJSON = routine.conditioningPlanJSON else {
            return false
        }

        if !routine.blocks.contains(where: { $0.kind == .conditioning }) {
            let movementIDs = Set(
                ConditioningPlan.decode(from: conditioningJSON)?
                    .sections.flatMap(\.movements).map(\.exerciseID) ?? []
            )
            let legacyRows = routine.exercises.filter {
                movementIDs.contains($0.exerciseID)
            }
            let block = RoutineBlockModel(
                userID: routine.userID,
                kind: .conditioning,
                position: legacyRows.map(\.position).min() ?? routine.exercises.count,
                planJSON: conditioningJSON
            )
            modelContext.insert(block)
            routine.blocks.append(block)

            for exercise in legacyRows {
                modelContext.delete(exercise)
            }
            let removedIDs = Set(legacyRows.map(\.id))
            routine.exercises.removeAll { removedIDs.contains($0.id) }
        }

        // An existing first-class conditioning block wins, matching the editor's
        // prior behavior; the obsolete workout-wide field is still cleared.
        routine.conditioningPlanJSON = nil
        return true
    }

    private static func migrateYogaIfNeeded(
        routine: RoutineModel,
        exercises: [ExerciseLibraryModel],
        in modelContext: ModelContext
    ) -> Bool {
        let yogaExerciseIDs = Set(exercises.lazy.filter(\.isYoga).map(\.id))
        let legacyRows = routine.exercises.filter {
            yogaExerciseIDs.contains($0.exerciseID) || $0.yogaFlowJSON != nil
        }
        guard !legacyRows.isEmpty else { return false }

        for row in legacyRows {
            let block = RoutineBlockModel(
                userID: routine.userID,
                kind: .yoga,
                position: row.position,
                planJSON: row.yogaFlowJSON
            )
            modelContext.insert(block)
            routine.blocks.append(block)
            modelContext.delete(row)
        }
        let removedIDs = Set(legacyRows.map(\.id))
        routine.exercises.removeAll { removedIDs.contains($0.id) }
        return true
    }
}
