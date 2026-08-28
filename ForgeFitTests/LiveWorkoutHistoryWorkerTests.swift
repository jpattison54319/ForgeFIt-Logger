import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@Suite("Live workout history worker")
struct LiveWorkoutHistoryWorkerTests {
    @Test("Reference request gate coalesces identical work and rejects stale results")
    func requestGateRejectsStaleResults() {
        let workoutID = UUID()
        let firstInput = LiveWorkoutReferenceInput(
            workoutID: workoutID,
            routineID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            exerciseIDs: [UUID()]
        )
        let changedInput = LiveWorkoutReferenceInput(
            workoutID: workoutID,
            routineID: firstInput.routineID,
            startedAt: firstInput.startedAt,
            exerciseIDs: firstInput.exerciseIDs.union([UUID()])
        )
        var gate = LiveWorkoutReferenceRequestGate()

        let first = gate.begin(firstInput)
        let duplicate = gate.begin(firstInput)
        #expect(first.startsNewWork)
        #expect(!duplicate.startsNewWork)
        #expect(duplicate.request == first.request)

        let replacement = gate.begin(changedInput)
        #expect(replacement.startsNewWork)
        #expect(!gate.shouldApply(first.request, currentInput: changedInput))
        #expect(gate.shouldApply(replacement.request, currentInput: changedInput))
        #expect(!gate.shouldApply(replacement.request, currentInput: firstInput))

        let didFinishReplacement = gate.finish(replacement.request)
        #expect(didFinishReplacement)
        let restarted = gate.begin(changedInput)
        #expect(restarted.startsNewWork)
        #expect(restarted.request.generation > replacement.request.generation)

        gate.cancel()
        #expect(!gate.shouldApply(restarted.request, currentInput: changedInput))
    }

    @MainActor
    @Test("Reference projection preserves routine-first previous values off MainActor")
    func referenceProjectionPreservesSemantics() async throws {
        let (container, context) = try TestStore.make()
        let routineID = UUID()
        let strengthID = UUID()
        let cardioID = UUID()
        let base = Date(timeIntervalSince1970: 10_000)

        let routineStrength = completedSet(position: 0, type: .working, reps: 8, weight: 80, at: base)
        let routineCardioExercise = exercise(cardioID, sets: [])
        let routineCardioSession = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: routineCardioExercise.id,
            modality: "running",
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            durationSeconds: 2_000,
            distanceMeters: 4_000,
            avgHR: 140
        )
        let routineWorkout = workout(
            routineID: routineID,
            startedAt: base,
            exercises: [exercise(strengthID, sets: [routineStrength]), routineCardioExercise],
            cardioSessions: [routineCardioSession]
        )

        let fallbackWarmup = completedSet(position: 0, type: .warmup, reps: 10, weight: 20, at: base.addingTimeInterval(100))
        let fallbackWorking = completedSet(position: 1, type: .working, reps: 5, weight: 90, at: base.addingTimeInterval(101))
        let cardioExercise = exercise(cardioID, sets: [])
        let cardioSession = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: cardioExercise.id,
            modality: "running",
            startedAt: base.addingTimeInterval(100),
            endedAt: base.addingTimeInterval(160),
            durationSeconds: 1_800,
            distanceMeters: 5_000,
            avgHR: 152
        )
        let fallbackWorkout = workout(
            routineID: nil,
            startedAt: base.addingTimeInterval(100),
            exercises: [
                exercise(strengthID, sets: [fallbackWarmup, fallbackWorking]),
                cardioExercise
            ],
            cardioSessions: [cardioSession]
        )

        // A newer soft-deleted session must not replace the newest live
        // cardio result, even though its parent workout is still in history.
        let deletedCardioExercise = exercise(cardioID, sets: [])
        let deletedCardioSession = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: deletedCardioExercise.id,
            modality: "running",
            startedAt: base.addingTimeInterval(150),
            endedAt: base.addingTimeInterval(190),
            durationSeconds: 900,
            distanceMeters: 99_000,
            avgHR: 190,
            deletedAt: base.addingTimeInterval(195)
        )
        let workoutWithDeletedCardio = workout(
            routineID: nil,
            startedAt: base.addingTimeInterval(150),
            exercises: [deletedCardioExercise],
            cardioSessions: [deletedCardioSession]
        )

        let activeSet = completedSet(position: 0, type: .working, reps: 1, weight: 999, at: base.addingTimeInterval(250))
        let active = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            startedAt: base.addingTimeInterval(200),
            exercises: [exercise(strengthID, sets: [activeSet])]
        )
        context.insert(routineWorkout)
        context.insert(fallbackWorkout)
        context.insert(workoutWithDeletedCardio)
        context.insert(active)
        try context.save()

        let worker = LiveWorkoutHistoryWorker(modelContainer: container)
        let snapshot = try await worker.referenceSnapshot(for: LiveWorkoutReferenceInput(
            workoutID: active.id,
            routineID: routineID,
            startedAt: active.startedAt,
            exerciseIDs: [strengthID, cardioID]
        ))

        #expect(await worker.isExecutingOnMainThreadForTesting() == false)
        #expect(snapshot.recordBaselines[strengthID]?.maxLoad == 90)
        #expect(snapshot.recordBaselines[strengthID]?.maxLoad != 999)

        let strengthPrevious = snapshot.previousSetsByExerciseID[strengthID] ?? []
        #expect(strengthPrevious.first { $0.setType == .working }?.weight == 80)
        #expect(strengthPrevious.first { $0.setType == .warmup }?.weight == 20)
        // Cardio remains newest-global even though strength explicitly favors
        // the older workout from this routine.
        #expect(snapshot.previousCardioByExerciseID[cardioID] == LivePreviousCardioSnapshot(
            distanceMeters: 5_000,
            durationSeconds: 1_800,
            averageHeartRate: 152
        ))
    }

    @MainActor
    @Test("Picker projection preserves generic and completed-session usage semantics")
    func pickerProjectionPreservesUsageSemantics() async throws {
        let (container, context) = try TestStore.make()
        let usedStrengthID = UUID()
        let plannedOnlyID = UUID()
        let cardioID = UUID()
        let unrelatedID = UUID()
        let base = Date(timeIntervalSince1970: 40_000)

        let firstStrengthRow = exercise(usedStrengthID, sets: [
            completedSet(position: 0, type: .working, reps: 5, weight: 50, at: base)
        ])
        // Generic suggestions historically count rows, while replacement
        // usage deduplicates the exercise within one completed workout.
        let duplicateStrengthRow = exercise(usedStrengthID, sets: [])
        let plannedOnlyRow = exercise(plannedOnlyID, sets: [])
        let cardioRow = exercise(cardioID, sets: [])
        let cardioSession = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: cardioRow.id,
            modality: "running",
            startedAt: base,
            endedAt: base.addingTimeInterval(60),
            durationSeconds: 60
        )
        let usedWorkout = workout(
            routineID: nil,
            startedAt: base,
            exercises: [firstStrengthRow, duplicateStrengthRow, plannedOnlyRow, cardioRow],
            cardioSessions: [cardioSession]
        )
        usedWorkout.updatedAt = base.addingTimeInterval(90)
        let unrelatedWorkout = workout(
            routineID: nil,
            startedAt: base.addingTimeInterval(100),
            exercises: [exercise(unrelatedID, sets: [
                completedSet(
                    position: 0,
                    type: .working,
                    reps: 8,
                    weight: 20,
                    at: base.addingTimeInterval(100)
                )
            ])]
        )
        unrelatedWorkout.updatedAt = base.addingTimeInterval(190)
        let active = WorkoutModel(
            userID: ForgeFitDemo.userID,
            startedAt: base.addingTimeInterval(200),
            exercises: [exercise(plannedOnlyID, sets: [])]
        )
        context.insert(usedWorkout)
        context.insert(unrelatedWorkout)
        context.insert(active)
        try context.save()

        let worker = LiveWorkoutHistoryWorker(modelContainer: container)
        let snapshot = try await worker.referenceSnapshot(for: LiveWorkoutReferenceInput(
            workoutID: active.id,
            routineID: nil,
            startedAt: active.startedAt,
            exerciseIDs: []
        )).pickerHistory

        #expect(snapshot.completedWorkoutCount == 2)
        #expect(snapshot.latestWorkoutUpdatedAt == unrelatedWorkout.updatedAt)
        #expect(snapshot.occurrenceCountByExerciseID[usedStrengthID] == 2)
        #expect(snapshot.occurrenceCountByExerciseID[plannedOnlyID] == 1)
        #expect(snapshot.occurrenceCountByExerciseID[cardioID] == 1)
        #expect(snapshot.completedWorkoutCountByExerciseID[usedStrengthID] == 1)
        #expect(snapshot.completedWorkoutCountByExerciseID[plannedOnlyID] == nil)
        #expect(snapshot.completedWorkoutCountByExerciseID[cardioID] == 1)
        #expect(snapshot.swapUsageProfiles[usedStrengthID]?.completedWorkoutCount == 1)

        let matchingIDs = try await worker.completedWorkoutIDs(containing: usedStrengthID)
        #expect(matchingIDs == [usedWorkout.id])
    }

    @MainActor
    @Test("Picker detail refetch revalidates terminal and deletion state")
    func pickerDetailRefetchRevalidatesHistoryRows() throws {
        let (container, context) = try TestStore.make()
        let base = Date(timeIntervalSince1970: 50_000)
        let live = workout(
            routineID: nil,
            startedAt: base,
            exercises: [exercise(UUID(), sets: [])]
        )
        let deleted = workout(
            routineID: nil,
            startedAt: base.addingTimeInterval(100),
            exercises: [exercise(UUID(), sets: [])]
        )
        deleted.deletedAt = base.addingTimeInterval(200)
        let unfinished = WorkoutModel(
            userID: ForgeFitDemo.userID,
            startedAt: base.addingTimeInterval(300)
        )
        context.insert(live)
        context.insert(deleted)
        context.insert(unfinished)
        try context.save()

        let rows = try context.fetch(
            ExercisePickerHistoryDetailDestination.completedHistoryDescriptor(
                for: [live.id, deleted.id, unfinished.id]
            )
        )

        #expect(rows.map(\.id) == [live.id])
        _ = container
    }

    @MainActor
    @Test("Completion projection uses the latest comparable workout and fresh routine targets")
    func completionProjectionUsesHistoryAndRoutineStore() async throws {
        let (container, context) = try TestStore.make()
        let routineID = UUID()
        let sourceRoutineExerciseID = UUID()
        let exerciseID = UUID()
        let base = Date(timeIntervalSince1970: 20_000)

        let target = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            targetRepsLow: 6,
            targetRepsHigh: 10
        )
        let routineExercise = RoutineExerciseModel(
            id: sourceRoutineExerciseID,
            userID: ForgeFitDemo.userID,
            exerciseID: exerciseID,
            sets: [target]
        )
        routineExercise.progressionRuleJSON = ProgressionRule.fixedIncrement(step: 2.5).encodedJSON()
        context.insert(RoutineModel(
            id: routineID,
            userID: ForgeFitDemo.userID,
            name: "Upper",
            exercises: [routineExercise]
        ))

        let older = workout(
            routineID: routineID,
            startedAt: base,
            exercises: [exercise(exerciseID, sets: [
                completedSet(position: 0, type: .working, reps: 5, weight: 50, at: base)
            ])]
        )
        let latest = workout(
            routineID: routineID,
            startedAt: base.addingTimeInterval(100),
            exercises: [exercise(exerciseID, sets: [
                completedSet(position: 0, type: .working, reps: 5, weight: 60, at: base.addingTimeInterval(100))
            ])]
        )
        let active = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            title: "Upper",
            startedAt: base.addingTimeInterval(200)
        )
        context.insert(older)
        context.insert(latest)
        context.insert(active)
        try context.save()

        let projection = try await LiveWorkoutHistoryWorker(modelContainer: container)
            .postWorkoutHistorySnapshot(for: PostWorkoutHistoryInput(
                workoutID: active.id,
                routineID: routineID,
                title: active.title,
                startedAt: active.startedAt
            ))

        #expect(projection.previousComparableVolume == 300)
        #expect(projection.recordBaselines[exerciseID]?.maxLoad == 60)
        #expect(projection.routineProgressionByExerciseID[sourceRoutineExerciseID] == LiveRoutineProgressionSnapshot(
            progressionRuleJSON: routineExercise.progressionRuleJSON,
            targetRepsLow: 6,
            targetRepsHigh: 10
        ))
    }

    @MainActor
    @Test("Value-only modality projection matches the established award engine")
    func modalityProjectionMatchesEstablishedAwards() async throws {
        let (container, context) = try TestStore.make()
        let base = Date(timeIntervalSince1970: 30_000)
        let movementID = UUID()

        let prior = conditioningWorkout(
            startedAt: base,
            movementID: movementID,
            elapsed: 100,
            roundCompletions: [50, 100],
            ended: true
        )
        let current = conditioningWorkout(
            startedAt: base.addingTimeInterval(200),
            movementID: movementID,
            elapsed: 90,
            roundCompletions: [40, 90],
            ended: false
        )
        context.insert(prior)
        context.insert(current)
        try context.save()

        let projection = try await LiveWorkoutHistoryWorker(modelContainer: container)
            .postWorkoutHistorySnapshot(for: PostWorkoutHistoryInput(
                workoutID: current.id,
                routineID: nil,
                title: current.title,
                startedAt: current.startedAt
            ))
        let established = WorkoutAwards.modalityAwards(
            for: current,
            history: [prior, current]
        )
        let projected = WorkoutAwards.modalityAwards(
            for: current,
            history: projection.modalityHistory
        )

        #expect(projected == established)
        #expect(projected.map(\.kind).contains(.conditioningBestTime))
        #expect(projected.map(\.kind).contains(.conditioningFastestRound))
    }

    @MainActor
    private func completedSet(
        position: Int,
        type: SetType,
        reps: Int,
        weight: Double,
        at date: Date
    ) -> SetModel {
        SetModel(
            userID: ForgeFitDemo.userID,
            position: position,
            setType: type,
            reps: reps,
            weight: weight,
            completedAt: date
        )
    }

    @MainActor
    private func exercise(_ exerciseID: UUID, sets: [SetModel]) -> WorkoutExerciseModel {
        WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exerciseID,
            sets: sets
        )
    }

    @MainActor
    private func workout(
        routineID: UUID?,
        startedAt: Date,
        exercises: [WorkoutExerciseModel],
        cardioSessions: [CardioSessionModel] = []
    ) -> WorkoutModel {
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: routineID,
            title: routineID == nil ? "Other" : "Upper",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            exercises: exercises,
            cardioSessions: cardioSessions
        )
        workout.recomputeTotalVolume()
        return workout
    }

    @MainActor
    private func conditioningWorkout(
        startedAt: Date,
        movementID: UUID,
        elapsed: Int,
        roundCompletions: [Int],
        ended: Bool
    ) -> WorkoutModel {
        let section = ConditioningSection(
            name: "Two rounds",
            format: .forTime,
            rounds: 2,
            movements: [ConditioningMovement(
                exerciseID: movementID,
                targetValue: 10
            )]
        )
        let result = ConditioningSectionResult(
            id: section.id,
            format: section.format,
            scoreKind: .elapsedTime,
            elapsedSeconds: elapsed,
            fullRounds: 2,
            totalReps: 20,
            roundCompletionElapsedSeconds: roundCompletions,
            completed: true
        )
        return WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Conditioning",
            startedAt: startedAt,
            endedAt: ended ? startedAt.addingTimeInterval(TimeInterval(elapsed)) : nil,
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            conditioningResultJSON: ConditioningResult(sectionResults: [result]).encodedJSON()
        )
    }
}
