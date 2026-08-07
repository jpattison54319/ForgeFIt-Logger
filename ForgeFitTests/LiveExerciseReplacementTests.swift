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

    @Test func noCompletedSetsLeavesTheExerciseForNormalInPlaceReplacement() {
        let target = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            sets: [
                SetModel(userID: userID, position: 0, reps: 8),
                SetModel(userID: userID, position: 1, reps: 10),
            ]
        )
        let workout = WorkoutModel(userID: userID, exercises: [target])

        let result = LiveExerciseReplacement.splitIfNeeded(
            target: target,
            replacementExerciseID: replacementExerciseID,
            replacementWeightMode: .external,
            replacementIsUnilateral: false,
            in: workout,
            now: now
        )

        #expect(result == nil)
        #expect(workout.exercises.count == 1)
        #expect(target.exerciseID == originalExerciseID)
        #expect(target.sets.count == 2)
    }

    @Test func completedSetsStayAndOnlyFreshUnfinishedSlotsMoveBelow() throws {
        let before = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 0)
        let firstCompleted = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            weightMode: .external,
            reps: 8,
            weight: 72.5,
            completedAt: now.addingTimeInterval(-120)
        )
        let unfinishedMyo = SetModel(
            userID: userID,
            position: 1,
            setType: .myoRep,
            weightMode: .external,
            reps: 14,
            weight: 60,
            rpe: 9,
            sourceRoutineSetID: UUID(),
            plannedMiniSetCount: 3
        )
        unfinishedMyo.miniReps = [4, 4]
        let secondCompleted = SetModel(
            userID: userID,
            position: 2,
            setType: .backoff,
            weightMode: .external,
            reps: 10,
            weight: 65,
            completedAt: now.addingTimeInterval(-60)
        )
        let unfinishedCluster = SetModel(
            userID: userID,
            position: 3,
            setType: .cluster,
            weightMode: .external,
            reps: 12,
            weight: 55,
            plannedMiniRepsJSON: "[4,4,4]"
        )
        unfinishedCluster.miniReps = [4, 4, 4]
        let target = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            position: 1,
            supersetGroup: 2,
            restSeconds: 150,
            microRestSeconds: 20,
            sets: [firstCompleted, unfinishedMyo, secondCompleted, unfinishedCluster]
        )
        let after = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: 2)
        let workout = WorkoutModel(userID: userID, exercises: [before, target, after])
        let (container, context) = try TestStore.make()
        _ = container
        context.insert(workout)
        try context.save()

        let result = try #require(LiveExerciseReplacement.splitIfNeeded(
            target: target,
            replacementExerciseID: replacementExerciseID,
            replacementWeightMode: .bodyweightAssisted,
            replacementIsUnilateral: true,
            in: workout,
            now: now
        ))
        result.discardedSets.forEach(context.delete)
        context.insert(result.replacement)
        try context.save()

        #expect(target.exerciseID == originalExerciseID)
        let retained = target.sets.sorted { $0.position < $1.position }
        #expect(retained.map(\.id) == [firstCompleted.id, secondCompleted.id])
        #expect(retained.map(\.position) == [0, 1])
        #expect(result.discardedSets.map(\.id) == [unfinishedMyo.id, unfinishedCluster.id])

        let orderedRows = workout.exercises.sorted { $0.position < $1.position }
        #expect(orderedRows.map(\.id) == [before.id, target.id, result.replacement.id, after.id])
        #expect(orderedRows.map(\.position) == [0, 1, 2, 3])
        #expect(result.replacement.exerciseID == replacementExerciseID)
        #expect(result.replacement.supersetGroup == nil)
        #expect(result.replacement.restSeconds == 150)
        #expect(result.replacement.microRestSeconds == 20)
        #expect(result.replacement.sets.count == 2)

        let moved = result.replacement.sets.sorted { $0.position < $1.position }
        #expect(moved.map(\.setType) == [.myoRep, .cluster])
        #expect(moved.allSatisfy { $0.completedAt == nil })
        #expect(moved.allSatisfy { $0.weightMode == .bodyweightAssisted })
        #expect(moved.allSatisfy { $0.isUnilateral })
        #expect(moved.allSatisfy { $0.reps == nil && $0.modeWeight == nil && $0.rpe == nil })
        #expect(moved.allSatisfy { $0.miniReps.isEmpty })
        #expect(moved.allSatisfy { $0.sourceRoutineSetID == nil })
        #expect(moved[0].plannedMiniSetCount == 3)
        #expect(moved[1].plannedMiniReps == [4, 4, 4])

        let persisted = try #require(context.fetch(FetchDescriptor<WorkoutModel>()).first)
        let persistedRows = persisted.exercises.sorted { $0.position < $1.position }
        #expect(persistedRows.count == 4)
        #expect(persistedRows[1].exerciseID == originalExerciseID)
        #expect(persistedRows[1].sets.count == 2)
        #expect(persistedRows[2].exerciseID == replacementExerciseID)
        #expect(persistedRows[2].sets.count == 2)
    }

    @Test func fullyCompletedExerciseStaysAndAddsAnEmptyReplacementBelow() throws {
        let completed = SetModel(userID: userID, reps: 8, completedAt: now)
        let target = WorkoutExerciseModel(
            userID: userID,
            exerciseID: originalExerciseID,
            sets: [completed]
        )
        let workout = WorkoutModel(userID: userID, exercises: [target])

        let result = try #require(LiveExerciseReplacement.splitIfNeeded(
            target: target,
            replacementExerciseID: replacementExerciseID,
            replacementWeightMode: .external,
            replacementIsUnilateral: false,
            in: workout,
            now: now
        ))

        #expect(target.sets.map(\.id) == [completed.id])
        #expect(result.discardedSets.isEmpty)
        #expect(result.replacement.sets.isEmpty)
        #expect(workout.exercises.sorted { $0.position < $1.position }.map(\.id) == [
            target.id,
            result.replacement.id,
        ])
    }
}
