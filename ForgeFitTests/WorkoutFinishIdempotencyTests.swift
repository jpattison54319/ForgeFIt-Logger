import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-006 — Workout Finish Idempotency.
///
/// A rapid repeat finish must not double-dispatch completion side effects.
/// Defense in depth: the UI holds a per-surface in-flight gate (`InFlightGate`)
/// and the finisher short-circuits on the persisted terminal state
/// (`endedAt`/`deletedAt`) before mutating anything. These tests count
/// dispatch through the per-call `FinishEffects` seam — they assert SCHEDULING
/// exactly-once and never claim a real HealthKit write.
@MainActor
struct WorkoutFinishIdempotencyTests {
    private let userID = UUID()

    @Test func doubleFinishDispatchesEachEffectAtMostOnce() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let recorder = FinishRecorder()
        UserDefaults.standard.set(true, forKey: "healthWriteEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "healthWriteEnabled") }

        let workout = substantiveLiveWorkout(in: context)

        // Both calls are honored; only the first reaches the side effects.
        let first = WorkoutFinisher.finish(workout, in: context, effects: recorder.effects())
        let second = WorkoutFinisher.finish(workout, in: context, effects: recorder.effects())

        #expect(first == nil)
        #expect(second == nil)
        #expect(workout.endedAt != nil)
        #expect(recorder.healthKitSaveCount == 1)
        #expect(recorder.watchSendCount == 1)
        #expect(recorder.watchPublishCount == 1)
        #expect(recorder.backupNoteCount == 1)
        // No BLE buffer exists in tests; the guarantee is "at most once".
        #expect(recorder.heartRateSaveCount <= 1)
    }

    @Test func doubleFinishAwardsXPOnce() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let recorder = FinishRecorder()
        UserDefaults.standard.set(true, forKey: "healthWriteEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "healthWriteEnabled") }

        let workout = substantiveLiveWorkout(in: context)

        _ = WorkoutFinisher.finish(workout, in: context, effects: recorder.effects())
        _ = WorkoutFinisher.finish(workout, in: context, effects: recorder.effects())

        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).count == 1)
        let progress = try #require(context.fetch(FetchDescriptor<UserProgressModel>()).first)
        #expect(progress.totalXP == workout.xpAwardedAmount)
    }

    @Test func distinctWorkoutsDispatchIndependently() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let recorder = FinishRecorder()
        UserDefaults.standard.set(true, forKey: "healthWriteEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "healthWriteEnabled") }

        let a = substantiveLiveWorkout(in: context)
        let b = substantiveLiveWorkout(in: context)

        _ = WorkoutFinisher.finish(a, in: context, effects: recorder.effects())
        _ = WorkoutFinisher.finish(b, in: context, effects: recorder.effects())

        #expect(a.endedAt != nil)
        #expect(b.endedAt != nil)
        #expect(recorder.healthKitSaveCount == 2)
        #expect(recorder.watchSendCount == 2)
        #expect(recorder.watchPublishCount == 2)
        #expect(recorder.backupNoteCount == 2)
    }

    @Test func repeatDiscardIsANoOp() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = WorkoutModel(userID: userID)
        context.insert(workout)

        let first = WorkoutFinisher.discard(workout, in: context)
        let second = WorkoutFinisher.discard(workout, in: context)

        #expect(first == nil)
        #expect(second == nil)
        #expect(workout.deletedAt != nil)
    }

    /// The retry contract: a terminal-save failure must roll back the
    /// in-memory `endedAt` (via the same rollback `saveReportingFailure`
    /// performs) so the same workout is processed again — and only then
    /// dispatches once.
    @Test func failedTerminalSaveLeavesWorkoutRetryable() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let recorder = FinishRecorder()
        UserDefaults.standard.set(true, forKey: "healthWriteEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "healthWriteEnabled") }

        // XP-eligible on purpose: XP must share the finisher's terminal save
        // boundary. A failed save rolls back endedAt, the award stamp,
        // progress, and the event together.
        let workout = substantiveLiveWorkout(in: context)

        let first = WorkoutFinisher.finish(
            workout, in: context,
            effects: recorder.effects(),
            terminalSave: { store in
                store.rollback()
                return "simulated persistent store failure"
            }
        )

        #expect(first == "simulated persistent store failure")
        #expect(workout.endedAt == nil)
        #expect(workout.xpAwardedAt == nil)
        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<UserProgressModel>()).isEmpty)
        #expect(recorder.healthKitSaveCount == 0)
        #expect(recorder.watchSendCount == 0)
        #expect(recorder.backupNoteCount == 0)

        // Retry with the real save succeeds and dispatches exactly once.
        let second = WorkoutFinisher.finish(workout, in: context, effects: recorder.effects())

        #expect(second == nil)
        #expect(workout.endedAt != nil)
        #expect(recorder.healthKitSaveCount == 1)
        #expect(recorder.watchSendCount == 1)
        #expect(recorder.watchPublishCount == 1)
        #expect(recorder.backupNoteCount == 1)
        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).count == 1)
        let progress = try #require(context.fetch(FetchDescriptor<UserProgressModel>()).first)
        #expect(progress.totalXP == workout.xpAwardedAmount)
    }

    /// A yoga split is created inside the same terminal transaction as the
    /// workout finish. If that transaction rolls back, its durable hold
    /// checkpoint must survive so the retry can recreate exactly the same
    /// partial credit rather than losing the user's final hold.
    @Test func failedTerminalSavePreservesYogaCheckpointForExactRetry() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let recorder = FinishRecorder()
        let end = Date(timeIntervalSince1970: 9_000_010)

        let pose = ExerciseLibraryModel(
            name: "Forward Fold",
            modalityRaw: "yoga",
            defaultHoldSeconds: 30
        )
        let plan = YogaFlowPlan(style: .hatha, steps: [
            YogaFlowPlan.PoseStep(
                poseID: pose.id,
                name: pose.name,
                holdSeconds: 30
            )
        ])
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: pose.id,
            yogaFlowJSON: plan.encodedJSON()
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: end.addingTimeInterval(-10),
            sourceDevice: "iphone"
        )
        let session = CardioSessionModel(
            userID: userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: workout.startedAt,
            liveStartedAt: workout.startedAt
        )
        workout.exercises = [workoutExercise]
        workout.cardioSessions = [session]
        context.insert(pose)
        context.insert(workout)
        try context.save()
        let workoutID = workout.id
        let sessionID = session.id

        YogaRuntimeCheckpointStore.save(
            YogaRuntimeCheckpoint(
                stepIndex: 0,
                elapsedSeconds: 7,
                isPaused: true,
                capturedAt: end
            ),
            sessionID: sessionID
        )
        defer { YogaRuntimeCheckpointStore.clear(sessionID: sessionID) }

        let first = WorkoutFinisher.finish(
            workout,
            in: context,
            endedAt: end,
            effects: recorder.effects(),
            terminalSave: { store in
                store.rollback()
                return "simulated persistent store failure"
            }
        )

        #expect(first == "simulated persistent store failure")
        #expect(workout.endedAt == nil)
        let rolledBackSplits = try context.fetch(FetchDescriptor<CardioSplitModel>(
            predicate: #Predicate { $0.cardioSessionID == sessionID }
        ))
        #expect(rolledBackSplits.isEmpty)
        #expect(YogaRuntimeCheckpointStore.load(sessionID: sessionID)?.elapsedSeconds == 7)
        #expect(recorder.healthKitSaveCount == 0)

        // Rollback invalidates SwiftData relationship snapshots. Refetch in a
        // fresh context, as a relaunch/recovery retry does, instead of reading
        // a stale to-many proxy from the failed transaction.
        let retryContext = ModelContext(container)
        let retryWorkout = try #require(retryContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        let second = WorkoutFinisher.finish(
            retryWorkout,
            in: retryContext,
            endedAt: end,
            effects: recorder.effects()
        )

        #expect(second == nil)
        #expect(retryWorkout.endedAt == end)
        let committedSession = try #require(retryContext.fetch(FetchDescriptor<CardioSessionModel>(
            predicate: #Predicate { $0.id == sessionID }
        )).first)
        let committedSplits = try retryContext.fetch(FetchDescriptor<CardioSplitModel>(
            predicate: #Predicate { $0.cardioSessionID == sessionID }
        ))
        #expect(committedSession.endedAt == end)
        #expect(committedSplits.count == 1)
        #expect(committedSplits.first?.durationSeconds == 7)
        #expect(YogaRuntimeCheckpointStore.load(sessionID: sessionID) == nil)
        #expect(recorder.healthKitSaveCount == 1)
    }

    /// The UI gate contract: held from the first commit, rejects a second
    /// commit while held, re-opens when the caller surfaces a failure.
    @Test func inFlightGateBlocksReentryAndReopens() {
        let gate = WorkoutFinisher.InFlightGate()

        #expect(gate.tryBegin())
        #expect(!gate.tryBegin()) // second immediate tap rejected while in flight
        gate.end()
        #expect(gate.tryBegin()) // retry after a surfaced failure re-opens
        gate.end()
        #expect(!gate.isActive)
    }

    /// Symmetric to the finish path: `discard(workoutID:)` also commits in an
    /// isolated transaction, so the caller's long-lived instance must come
    /// back tombstoned too. ContentView's active-workout query filters on
    /// `deletedAt == nil` against exactly that instance.
    @Test func isolatedDiscardTombstonesCallerInstance() throws {
        let (container, context) = try TestStore.make()
        let workout = substantiveLiveWorkout(in: context)
        let workoutID = workout.id
        try context.save()

        let failure = WorkoutFinisher.discard(workoutID: workoutID, in: context)
        #expect(failure == nil)

        let verificationContext = ModelContext(container)
        let persisted = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        #expect(persisted.deletedAt != nil)

        #expect(workout.deletedAt != nil)
    }

    @Test func isolatedTerminalFailurePreservesUnrelatedPendingEditAndRetryCommitsOnce() throws {
        let (container, context) = try TestStore.make()
        let recorder = FinishRecorder()
        let workout = substantiveLiveWorkout(in: context)
        let workoutID = workout.id
        let routine = RoutineModel(userID: userID, name: "Before")
        context.insert(routine)
        try context.save()
        let routineID = routine.id
        routine.name = "Still pending"

        let first = WorkoutFinisher.finish(
            workoutID: workoutID,
            in: context,
            effects: recorder.effects(),
            terminalSave: { transaction in
                transaction.rollback()
                return "simulated persistent store failure"
            }
        )

        #expect(first == "simulated persistent store failure")
        #expect(routine.name == "Still pending")
        #expect(context.hasChanges)
        var verificationContext = ModelContext(container)
        var persistedWorkout = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        #expect(persistedWorkout.endedAt == nil)
        #expect(recorder.healthKitSaveCount == 0)
        #expect(recorder.watchSendCount == 0)
        #expect(recorder.backupNoteCount == 0)

        let retry = WorkoutFinisher.finish(
            workoutID: workoutID,
            in: context,
            effects: recorder.effects()
        )
        #expect(retry == nil)
        // The isolated save must also make the caller's long-lived instance
        // terminal immediately. ContentView's active-workout query and the
        // Watch publisher both observe this instance after a Cindy save.
        #expect(workout.endedAt != nil)
        #expect(workout.deletedAt == nil)
        #expect(routine.name == "Still pending")
        #expect(context.hasChanges)
        #expect(recorder.healthKitSaveCount == 1)
        #expect(recorder.watchSendCount == 1)
        #expect(recorder.watchPublishCount == 1)
        #expect(recorder.backupNoteCount == 1)

        try context.save()
        verificationContext = ModelContext(container)
        persistedWorkout = try #require(try verificationContext.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        let persistedRoutine = try #require(try verificationContext.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(persistedWorkout.endedAt != nil)
        #expect(persistedRoutine.name == "Still pending")
    }

    /// The reported end-of-workout path: accepting a swap/reorder must be part
    /// of the isolated terminal transaction. Failure leaves both models live
    /// and unchanged; retry commits the exact routine graph once and mirrors it
    /// into the long-lived UI context.
    @Test func acceptedRoutineUpdateIsAtomicWithFinishAndRetry() throws {
        let (container, context) = try TestStore.make()
        let recorder = FinishRecorder()
        let originalA = UUID()
        let replacementA = UUID()
        let exerciseB = UUID()
        let targetA = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetWeight: 60)
        let targetB = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 5, targetWeight: 90)
        let routineA = RoutineExerciseModel(
            userID: userID,
            exerciseID: originalA,
            position: 0,
            sets: [targetA]
        )
        let routineB = RoutineExerciseModel(
            userID: userID,
            exerciseID: exerciseB,
            position: 1,
            sets: [targetB]
        )
        let routine = RoutineModel(userID: userID, name: "Atomic", exercises: [routineA, routineB])

        let completedAt = Date.now.addingTimeInterval(-30)
        let workoutA = WorkoutExerciseModel(
            userID: userID,
            exerciseID: replacementA,
            position: 1,
            sourceRoutineExerciseID: routineA.id,
            sets: [SetModel(
                userID: userID,
                position: 0,
                reps: 8,
                weight: 55,
                sourceRoutineSetID: targetA.id,
                completedAt: completedAt
            )]
        )
        let workoutB = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exerciseB,
            position: 0,
            sourceRoutineExerciseID: routineB.id,
            sets: [SetModel(
                userID: userID,
                position: 0,
                reps: 5,
                weight: 90,
                sourceRoutineSetID: targetB.id,
                completedAt: completedAt
            )]
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            startedAt: Date.now.addingTimeInterval(-600),
            sourceDevice: "iphone",
            exercises: [workoutA, workoutB]
        )
        workout.avgHR = 140
        workout.maxHR = 165
        workout.activeEnergyKcal = 200
        context.insert(routine)
        context.insert(workout)
        try context.save()
        let routineID = routine.id
        let workoutID = workout.id
        let summary = WorkoutFinisher.SummaryCommit(
            wholeSessionRPE: 8,
            wholeSessionRPERatedAt: completedAt,
            wholeSessionRPEProtocolVersion: "whole-session-cr10-immediate-v1",
            updateRoutine: true
        )

        let first = WorkoutFinisher.finish(
            workoutID: workoutID,
            in: context,
            summaryCommit: summary,
            effects: recorder.effects(),
            terminalSave: { transaction in
                transaction.rollback()
                return "simulated persistent store failure"
            }
        )

        #expect(first == "simulated persistent store failure")
        #expect(workout.endedAt == nil)
        #expect(workout.wholeSessionRPE == nil)
        #expect(routine.exercises.sorted { $0.position < $1.position }.map(\.exerciseID) == [originalA, exerciseB])
        var verification = ModelContext(container)
        var persistedRoutine = try #require(verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(persistedRoutine.exercises.sorted { $0.position < $1.position }.map(\.exerciseID) == [originalA, exerciseB])
        #expect(recorder.healthKitSaveCount == 0)

        let retry = WorkoutFinisher.finish(
            workoutID: workoutID,
            in: context,
            summaryCommit: summary,
            effects: recorder.effects()
        )

        #expect(retry == nil)
        #expect(workout.endedAt != nil)
        #expect(workout.wholeSessionRPE == 8)
        #expect(routine.exercises.sorted { $0.position < $1.position }.map(\.exerciseID) == [exerciseB, replacementA])
        #expect(routine.exercises.sorted { $0.position < $1.position }.map(\.position) == [0, 1])
        #expect(routine.exercises.count == 2)
        #expect(recorder.healthKitSaveCount == 1)
        #expect(recorder.watchSendCount == 1)
        #expect(recorder.backupNoteCount == 1)

        verification = ModelContext(container)
        persistedRoutine = try #require(verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        let persistedWorkout = try #require(verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        #expect(persistedRoutine.exercises.sorted { $0.position < $1.position }.map(\.exerciseID) == [exerciseB, replacementA])
        #expect(persistedRoutine.exercises.count == 2)
        #expect(persistedWorkout.endedAt != nil)
        #expect(persistedWorkout.wholeSessionRPE == 8)
        #expect(persistedWorkout.wholeSessionRPEProtocolVersion == "whole-session-cr10-immediate-v1")
    }

    // MARK: - Helpers

    /// A live strength workout with completed working sets (XP-eligible) and
    /// pre-stamped metrics so the finisher spawns no HealthKit fill Tasks.
    private func substantiveLiveWorkout(in context: ModelContext) -> WorkoutModel {
        let start = Date.now.addingTimeInterval(-600)
        let workout = WorkoutModel(userID: userID, startedAt: start, sourceDevice: "iphone")
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        exercise.sets = [
            SetModel(userID: userID, position: 0, setType: .working, reps: 10, weight: 100, completedAt: start.addingTimeInterval(60)),
            SetModel(userID: userID, position: 1, setType: .working, reps: 10, weight: 100, completedAt: start.addingTimeInterval(120))
        ]
        workout.exercises = [exercise]
        workout.avgHR = 140
        workout.maxHR = 165
        workout.activeEnergyKcal = 250
        context.insert(workout)
        try? context.save()
        return workout
    }

}

/// Counts one channel per finisher side effect. Handed to `finish` per call
/// via `FinishEffects`; distinct workouts share a recorder so independence
/// (not just at-most-once) is observable.
@MainActor
private final class FinishRecorder {
    var healthKitSaveCount = 0
    var heartRateSaveCount = 0
    var watchSendCount = 0
    var watchPublishCount = 0
    var backupNoteCount = 0

    func effects() -> WorkoutFinisher.FinishEffects {
        WorkoutFinisher.FinishEffects(
            scheduleHealthKitSave: { [self] _ in healthKitSaveCount += 1 },
            scheduleHeartRateSamples: { [self] _ in heartRateSaveCount += 1 },
            sendWorkoutFinishedToWatch: { [self] in watchSendCount += 1 },
            publishWatchState: { [self] in watchPublishCount += 1 },
            noteLogDataChanged: { [self] in backupNoteCount += 1 }
        )
    }
}
