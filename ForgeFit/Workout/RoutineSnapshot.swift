import Foundation
import ForgeData
import SwiftData

/// Value-type capture of a routine's editable state, taken when the editor
/// opens. Supports a real "discard changes": the editor mutates the live
/// SwiftData models as the user works (adds save eagerly so the picker flow
/// stays consistent), so discarding means restoring this snapshot onto the
/// models. IDs are preserved so references from live workouts
/// (`sourceRoutineExerciseID` / `sourceRoutineSetID`) stay valid.
struct RoutineSnapshot: Equatable {
    struct SetSnapshot: Equatable {
        let id: UUID
        let position: Int
        let setTypeRaw: String
        let targetRepsLow: Int?
        let targetRepsHigh: Int?
        let targetWeight: Double?
        let targetRPE: Double?
        let targetRIR: Int?
        let targetDurationSeconds: Int?

        init(of set: RoutineSetModel) {
            id = set.id
            position = set.position
            setTypeRaw = set.setTypeRaw
            targetRepsLow = set.targetRepsLow
            targetRepsHigh = set.targetRepsHigh
            targetWeight = set.targetWeight
            targetRPE = set.targetRPE
            targetRIR = set.targetRIR
            targetDurationSeconds = set.targetDurationSeconds
        }
    }

    struct ExerciseSnapshot: Equatable {
        let id: UUID
        let exerciseID: UUID
        let position: Int
        let supersetGroup: Int?
        let notes: String?
        let intervalPlanJSON: String?
        let sets: [SetSnapshot]

        init(of exercise: RoutineExerciseModel) {
            id = exercise.id
            exerciseID = exercise.exerciseID
            position = exercise.position
            supersetGroup = exercise.supersetGroup
            notes = exercise.notes
            intervalPlanJSON = exercise.intervalPlanJSON
            sets = exercise.sets.sorted { $0.position < $1.position }.map(SetSnapshot.init)
        }
    }

    let name: String
    let notes: String?
    let exercises: [ExerciseSnapshot]

    init(of routine: RoutineModel) {
        name = routine.name
        notes = routine.notes
        exercises = routine.exercises.sorted { $0.position < $1.position }.map(ExerciseSnapshot.init)
    }

    /// Put the routine back exactly as captured: updates surviving models in
    /// place (keyed by id), recreates deleted ones with their original ids, and
    /// deletes anything added since the snapshot.
    @MainActor
    func restore(onto routine: RoutineModel, in context: ModelContext) {
        routine.name = name
        routine.notes = notes

        let existingByID = Dictionary(routine.exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keptExerciseIDs = Set(exercises.map(\.id))

        var restored: [RoutineExerciseModel] = []
        for exerciseSnapshot in exercises {
            let model: RoutineExerciseModel
            if let existing = existingByID[exerciseSnapshot.id] {
                model = existing
            } else {
                model = RoutineExerciseModel(id: exerciseSnapshot.id, userID: routine.userID, exerciseID: exerciseSnapshot.exerciseID)
                context.insert(model)
            }
            model.exerciseID = exerciseSnapshot.exerciseID
            model.position = exerciseSnapshot.position
            model.supersetGroup = exerciseSnapshot.supersetGroup
            model.notes = exerciseSnapshot.notes
            model.intervalPlanJSON = exerciseSnapshot.intervalPlanJSON
            model.updatedAt = Date()
            restoreSets(exerciseSnapshot.sets, onto: model, userID: routine.userID, in: context)
            restored.append(model)
        }

        for orphan in routine.exercises where !keptExerciseIDs.contains(orphan.id) {
            context.delete(orphan)
        }
        routine.exercises = restored
        routine.updatedAt = Date()
        try? context.save()
    }

    @MainActor
    private func restoreSets(
        _ snapshots: [SetSnapshot],
        onto exercise: RoutineExerciseModel,
        userID: UUID,
        in context: ModelContext
    ) {
        let existingByID = Dictionary(exercise.sets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let keptIDs = Set(snapshots.map(\.id))

        var restored: [RoutineSetModel] = []
        for snapshot in snapshots {
            let model: RoutineSetModel
            if let existing = existingByID[snapshot.id] {
                model = existing
            } else {
                model = RoutineSetModel(id: snapshot.id, userID: userID)
                context.insert(model)
            }
            model.position = snapshot.position
            model.setTypeRaw = snapshot.setTypeRaw
            model.targetRepsLow = snapshot.targetRepsLow
            model.targetRepsHigh = snapshot.targetRepsHigh
            model.targetWeight = snapshot.targetWeight
            model.targetRPE = snapshot.targetRPE
            model.targetRIR = snapshot.targetRIR
            model.targetDurationSeconds = snapshot.targetDurationSeconds
            restored.append(model)
        }

        for orphan in exercise.sets where !keptIDs.contains(orphan.id) {
            context.delete(orphan)
        }
        exercise.sets = restored
    }
}
