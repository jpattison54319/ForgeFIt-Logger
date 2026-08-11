import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct LiveExerciseReplacementTests {
    private let userID = ForgeFitDemo.userID
    private let originalExerciseID = UUID(uuidString: "00000000-0000-7000-8000-00000000E101")!
    private let replacementExerciseID = UUID(uuidString: "00000000-0000-7000-8000-00000000E102")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func replacementKeepsOneRowAndEverySetIdentity() {
        let sourceIDs = [UUID(), UUID(), UUID()]
        let sets = sourceIDs.enumerated().map { index, sourceID in
            SetModel(
                userID: userID,
                position: index,
                setType: index == 1 ? .myoRep : .working,
                weightMode: .external,
                reps: 8 + index,
                weight: 72.5,
                rpe: 9,
                sourceRoutineSetID: sourceID,
                plannedMiniSetCount: index == 1 ? 3 : nil
            )
        }
        let target = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            position: 2,
            supersetGroup: 1,
            restSeconds: 150,
            microRestSeconds: 15,
            sets: sets
        )
        let workout = WorkoutModel(userID: userID, exercises: [target])
        let originalRowID = target.id
        let originalSetIDs = sets.map(\.id)

        LiveExerciseReplacement.replaceInPlace(
            target: target,
            replacementExerciseID: replacementExerciseID,
            replacementWeightMode: .bodyweightAssisted,
            replacementIsUnilateral: true,
            now: now
        )

        #expect(workout.exercises.count == 1)
        #expect(target.id == originalRowID)
        #expect(target.exerciseID == replacementExerciseID)
        #expect(target.position == 2)
        #expect(target.supersetGroup == 1)
        #expect(target.restSeconds == 150)
        #expect(target.microRestSeconds == 15)
        #expect(target.sets.sorted { $0.position < $1.position }.map(\.id) == originalSetIDs)
        #expect(target.sets.map(\.sourceRoutineSetID) == sourceIDs.map(Optional.some))
        #expect(target.sets.allSatisfy { $0.weightMode == .bodyweightAssisted })
        #expect(target.sets.allSatisfy { $0.isUnilateral })
        #expect(target.sets.allSatisfy { $0.reps == nil && $0.modeWeight == nil && $0.rpe == nil })
        #expect(target.sets[1].setType == .myoRep)
        #expect(target.sets[1].plannedMiniSetCount == 3)
    }

    @Test func completedDataStaysLoggedWhileEveryUnfinishedValueIsCleared() {
        let completed = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            weightMode: .external,
            reps: 8,
            weight: 72.5,
            rpe: 9,
            completedAt: now.addingTimeInterval(-60)
        )
        let unfinished = SetModel(
            userID: userID,
            position: 1,
            setType: .cluster,
            weightMode: .bodyweightAdded,
            reps: 12,
            weight: 55,
            rpe: 10,
            rir: 0,
            durationSeconds: 45,
            holdSeconds: 5,
            partialReps: 2,
            addedWeight: 20,
            assistanceWeight: 15,
            bodyweightKg: 80,
            isUnilateral: true,
            implementWeight: 4,
            limbCount: 2,
            machineSettingsJSON: "{\"seat\":3}",
            sourceRoutineSetID: UUID(),
            plannedMiniRepsJSON: "[4,4,4]"
        )
        unfinished.miniReps = [4, 4, 4]
        unfinished.side2Reps = 12
        unfinished.side2MiniReps = [4, 4, 4]
        let target = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            sets: [completed, unfinished]
        )

        LiveExerciseReplacement.replaceInPlace(
            target: target,
            replacementExerciseID: replacementExerciseID,
            replacementWeightMode: .external,
            replacementIsUnilateral: false,
            now: now
        )

        #expect(completed.reps == 8)
        #expect(completed.weight == 72.5)
        #expect(completed.rpe == 9)
        #expect(completed.completedAt != nil)
        #expect(completed.weightMode == .external)

        #expect(unfinished.completedAt == nil)
        #expect(unfinished.weightMode == .external)
        #expect(!unfinished.isUnilateral)
        #expect(unfinished.limbCount == 2)
        #expect(unfinished.reps == nil)
        #expect(unfinished.weight == nil)
        #expect(unfinished.rpe == nil)
        #expect(unfinished.rir == nil)
        #expect(unfinished.durationSeconds == nil)
        #expect(unfinished.holdSeconds == nil)
        #expect(unfinished.partialReps == nil)
        #expect(unfinished.addedWeight == nil)
        #expect(unfinished.assistanceWeight == nil)
        #expect(unfinished.bodyweightKg == nil)
        #expect(unfinished.implementWeight == nil)
        #expect(unfinished.machineSettingsJSON == nil)
        #expect(unfinished.miniRepsJSON == nil)
        #expect(unfinished.side2Reps == nil)
        #expect(unfinished.side2MiniRepsJSON == nil)
        #expect(unfinished.setType == .cluster)
        #expect(unfinished.plannedMiniReps == [4, 4, 4])
        #expect(unfinished.sourceRoutineSetID != nil)
        #expect(unfinished.updatedAt == now)
    }

    @Test func oneRowAndAllSetsPersistAfterReplacement() throws {
        let sets = (0..<3).map {
            SetModel(userID: userID, position: $0, reps: 10, weight: 50)
        }
        sets[0].completedAt = now.addingTimeInterval(-30)
        let target = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            sets: sets
        )
        let workout = WorkoutModel(userID: userID, exercises: [target])
        let rowID = target.id
        let setIDs = sets.map(\.id)
        let (container, context) = try TestStore.make()
        _ = container
        context.insert(workout)
        try context.save()

        LiveExerciseReplacement.replaceInPlace(
            target: target,
            replacementExerciseID: replacementExerciseID,
            replacementWeightMode: .external,
            replacementIsUnilateral: false,
            now: now
        )
        try context.save()

        let persisted = try #require(context.fetch(FetchDescriptor<WorkoutModel>()).first)
        #expect(persisted.exercises.count == 1)
        let persistedTarget = try #require(persisted.exercises.first)
        #expect(persistedTarget.id == rowID)
        #expect(persistedTarget.exerciseID == replacementExerciseID)
        #expect(persistedTarget.sets.sorted { $0.position < $1.position }.map(\.id) == setIDs)
        #expect(persistedTarget.sets.count == 3)
    }
}
