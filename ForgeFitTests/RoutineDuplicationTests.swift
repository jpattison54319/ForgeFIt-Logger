import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// Guards `RoutineDuplicator` against the field-drift bug it was extracted to
/// fix: an inline copy silently dropped myo/cluster plans, interval plans and
/// yoga flows, so "Duplicate Routine" degraded structured programming to
/// plain sets with no warning.
@MainActor
struct RoutineDuplicationTests {
    private let userID = ForgeFitDemo.userID

    /// A routine exercising every planned field at once: myo plan, cluster
    /// plan, targets, superset, progression rule, notes, interval plan and
    /// yoga flow.
    private func planHeavyRoutine(in context: ModelContext) -> RoutineModel {
        let myoSet = RoutineSetModel(
            userID: userID, position: 0, setType: .myoRep,
            targetWeight: 80, plannedMiniSetCount: 4
        )
        let clusterSet = RoutineSetModel(
            userID: userID, position: 1, setType: .cluster,
            targetWeight: 120, plannedMiniRepsJSON: "[3,3,3,3]"
        )
        let workingSet = RoutineSetModel(
            userID: userID, position: 2, setType: .working,
            targetRepsLow: 8, targetRepsHigh: 12, targetWeight: 100,
            targetRPE: 8, targetRIR: 2, targetDurationSeconds: 45
        )
        let strength = RoutineExerciseModel(
            userID: userID, exerciseID: UUID(), position: 0,
            supersetGroup: 1, progressionRuleID: UUID(), notes: "brace hard",
            sets: [myoSet, clusterSet, workingSet]
        )
        let cardio = RoutineExerciseModel(
            userID: userID, exerciseID: UUID(), position: 1,
            intervalPlanJSON: #"{"steps":[{"kind":"work","seconds":60}]}"#
        )
        let yoga = RoutineExerciseModel(
            userID: userID, exerciseID: UUID(), position: 2,
            yogaFlowJSON: #"{"poses":[{"name":"Balasana","holdSeconds":30}]}"#
        )
        let routine = RoutineModel(
            userID: userID, name: "Block A", notes: "week 3",
            folderID: UUID(), position: 2,
            exercises: [strength, cardio, yoga]
        )
        context.insert(routine)
        try? context.save()
        return routine
    }

    @Test func copyCarriesEveryPlannedField() throws {
        let context = ModelContext(try TestStore.makeContainer())
        let source = planHeavyRoutine(in: context)

        let copy = RoutineDuplicator.duplicate(source, position: 7, in: context)
        try context.save()

        #expect(copy.name == "Block A Copy")
        #expect(copy.notes == "week 3")
        #expect(copy.folderID == source.folderID)
        #expect(copy.position == 7)

        let sourceExercises = source.exercises.sorted { $0.position < $1.position }
        let copyExercises = copy.exercises.sorted { $0.position < $1.position }
        #expect(copyExercises.count == sourceExercises.count)

        for (original, copied) in zip(sourceExercises, copyExercises) {
            #expect(copied.exerciseID == original.exerciseID)
            #expect(copied.position == original.position)
            #expect(copied.supersetGroup == original.supersetGroup)
            #expect(copied.progressionRuleID == original.progressionRuleID)
            #expect(copied.notes == original.notes)
            // The two fields the old inline copy dropped on exercises:
            #expect(copied.intervalPlanJSON == original.intervalPlanJSON)
            #expect(copied.yogaFlowJSON == original.yogaFlowJSON)

            let originalSets = original.sets.sorted { $0.position < $1.position }
            let copiedSets = copied.sets.sorted { $0.position < $1.position }
            #expect(copiedSets.count == originalSets.count)
            for (s, c) in zip(originalSets, copiedSets) {
                #expect(c.setType == s.setType)
                #expect(c.position == s.position)
                #expect(c.targetRepsLow == s.targetRepsLow)
                #expect(c.targetRepsHigh == s.targetRepsHigh)
                #expect(c.targetWeight == s.targetWeight)
                #expect(c.targetRPE == s.targetRPE)
                #expect(c.targetRIR == s.targetRIR)
                #expect(c.targetDurationSeconds == s.targetDurationSeconds)
                // The two fields the old inline copy dropped on sets:
                #expect(c.plannedMiniSetCount == s.plannedMiniSetCount)
                #expect(c.plannedMiniRepsJSON == s.plannedMiniRepsJSON)
            }
        }
    }

    @Test func copyUsesFreshIdentityAndLeavesSourceUntouched() throws {
        let context = ModelContext(try TestStore.makeContainer())
        let source = planHeavyRoutine(in: context)
        let sourceExerciseIDs = Set(source.exercises.map(\.id))
        let sourceSetIDs = Set(source.exercises.flatMap(\.sets).map(\.id))
        let sourceExerciseCount = source.exercises.count

        let copy = RoutineDuplicator.duplicate(source, position: 3, in: context)
        try context.save()

        // Fresh IDs throughout — shared identity would make live workouts
        // started from one routine mutate the other's plan references.
        #expect(copy.id != source.id)
        #expect(Set(copy.exercises.map(\.id)).isDisjoint(with: sourceExerciseIDs))
        #expect(Set(copy.exercises.flatMap(\.sets).map(\.id)).isDisjoint(with: sourceSetIDs))

        // Source untouched (the old copy shared no state, keep it that way).
        #expect(source.exercises.count == sourceExerciseCount)
        #expect(source.name == "Block A")
        #expect(source.deletedAt == nil)
    }
}
