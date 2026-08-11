import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-013 — mid-hold endings (Complete, Skip, background/termination)
/// converge on one partial-credit semantic: the hold in progress at the stop
/// moment is recorded with the seconds actually held, and splits, pose count,
/// exposure, and history all derive from the recorded splits.
///
/// Runner-alive tests assert structural determinism (the credited duration is
/// never wall-clock dependent for a given pause state); model-level tests pin
/// exact durations from fixed timestamps. The no-live-runner backstop
/// (`YogaSessionCompletion.recordInterruptedHold`) is fully deterministic.
@MainActor
struct YogaPartialHoldCompletionTests {

    private struct RecordedSplit: Equatable {
        let index: Int
        let label: String
        let duration: Int
        let startedAt: Date
        let endedAt: Date
    }

    // MARK: - Fixtures

    private func insertPose(
        _ name: String,
        primary: [String],
        unilateral: Bool = false,
        in context: ModelContext
    ) -> ExerciseLibraryModel {
        let pose = ExerciseLibraryModel(name: name, modalityRaw: "yoga", defaultHoldSeconds: 30)
        pose.primaryMuscles = primary
        pose.isUnilateral = unilateral
        context.insert(pose)
        return pose
    }

    /// A two-hold hatha flow: Forward Fold then Low Lunge. Voice guidance is
    /// disabled so tests never narrate (caption-only).
    private func twoHoldFlow(_ fold: ExerciseLibraryModel, _ lunge: ExerciseLibraryModel) -> YogaFlowPlan {
        var flow = YogaFlowPlan(style: .hatha, steps: [
            YogaFlowPlan.PoseStep(poseID: fold.id, name: "Forward Fold", holdSeconds: 30),
            YogaFlowPlan.PoseStep(poseID: lunge.id, name: "Low Lunge", holdSeconds: 30)
        ])
        flow.voiceGuidanceEnabled = false
        return flow
    }

    private func liveSession(
        _ plan: YogaFlowPlan,
        exercise: ExerciseLibraryModel,
        startedAt: Date = .now,
        in context: ModelContext
    ) -> (session: CardioSessionModel, workoutExercise: WorkoutExerciseModel) {
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exercise.id,
            yogaFlowJSON: plan.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: startedAt,
            liveStartedAt: startedAt
        )
        context.insert(workoutExercise)
        context.insert(session)
        return (session, workoutExercise)
    }

    private func split(
        _ label: String,
        index: Int,
        duration: Int,
        startedAt: Date,
        endedAt: Date,
        session: CardioSessionModel,
        context: ModelContext
    ) {
        let split = CardioSplitModel(
            userID: session.userID,
            cardioSessionID: session.id,
            index: index,
            distanceMeters: 0,
            durationSeconds: duration,
            paceSecondsPerKm: 0,
            label: label,
            startedAt: startedAt,
            endedAt: endedAt
        )
        split.cardioSession = session
        context.insert(split)
        session.splits.append(split)
    }

    private func checkpoint(
        session: CardioSessionModel,
        stepIndex: Int,
        elapsed: Int = 0,
        paused: Bool = false,
        at date: Date
    ) {
        YogaRuntimeCheckpointStore.save(
            YogaRuntimeCheckpoint(
                stepIndex: stepIndex,
                elapsedSeconds: elapsed,
                isPaused: paused,
                capturedAt: date
            ),
            sessionID: session.id
        )
    }

    private func labeledSplits(_ session: CardioSessionModel) -> [RecordedSplit] {
        session.splits
            .filter { $0.label != nil }
            .map {
                RecordedSplit(
                    index: $0.index,
                    label: $0.label ?? "",
                    duration: $0.durationSeconds,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt
                )
            }
            .sorted { $0.index < $1.index }
    }

    // MARK: - Complete mid-hold (runner alive)

    @Test func runnerCompleteMidHoldRecordsCurrentPartialHold() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let lunge = insertPose("Low Lunge", primary: ["hips"], in: context)
        let flow = twoHoldFlow(fold, lunge)
        let (session, workoutExercise) = liveSession(flow, exercise: fold, in: context)
        try context.save()

        let hub = YogaFlowRunnerHub()
        hub.start(plan: flow, session: session, context: context)
        defer { hub.stop(for: session.id) }

        let runner = try #require(hub.runner(for: session.id))
        #expect(runner.currentIndex == 0)
        #expect(!runner.isFinished)

        hub.complete(for: session.id)

        // The runner stopped, finished, and credited exactly one hold: the one
        // that was in progress, with the seconds actually held.
        #expect(hub.runner(for: session.id) == nil)
        #expect(runner.isFinished)
        #expect(runner.currentIndex == runner.steps.count)
        let recorded = labeledSplits(session)
        let first = try #require(recorded.first)
        #expect(recorded.count == 1)
        #expect(first.index == 0)
        #expect(first.label == "Forward Fold")
        #expect(first.duration >= 1)
        #expect(first.duration <= 30)

        // The completion pipeline derives pose count, exposure, and history
        // from that split and must not record a second one.
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: fold,
            context: context,
            endedAt: .now,
            useClockDuration: true
        )
        #expect(labeledSplits(session).count == 1)
        #expect(session.posesCompleted == 1)
        #expect(YogaHistoryPresentation.poseCount(session: session, plan: flow) == 1)
        #expect(YogaHistoryPresentation.poses(session: session, plan: flow).count == 1)
        let exposure = FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
        #expect(exposure == ["hamstrings": first.duration])
        _ = container
    }

    @Test func runnerCompleteWhilePausedCreditsOnlySecondsHeldBeforePause() async throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let flow = twoHoldFlow(fold, insertPose("Low Lunge", primary: ["hips"], in: context))
        let (session, workoutExercise) = liveSession(flow, exercise: fold, in: context)
        try context.save()

        let hub = YogaFlowRunnerHub()
        hub.start(plan: flow, session: session, context: context)
        defer { hub.stop(for: session.id) }
        let runner = try #require(hub.runner(for: session.id))

        // Let ~2s of the 30s hold elapse, then pause. The runner captured the
        // remaining seconds at pause, so the credited duration is exactly the
        // seconds held before pausing — no wall-clock dependence in the
        // assertion.
        try await Task.sleep(for: .seconds(2.1))
        runner.pause()
        let heldBeforePause = 30 - runner.pausedRemaining
        #expect(heldBeforePause >= 1)

        hub.complete(for: session.id)

        let recorded = labeledSplits(session)
        let first = try #require(recorded.first)
        #expect(recorded.count == 1)
        #expect(first.duration == heldBeforePause)
        #expect(first.duration < 30)

        // The pipeline keeps the pause-exact duration: no reconcile, no change.
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: fold,
            context: context,
            endedAt: .now,
            useClockDuration: true
        )
        #expect(labeledSplits(session).count == 1)
        #expect(session.posesCompleted == 1)
        let exposure = FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
        #expect(exposure == ["hamstrings": heldBeforePause])
        _ = container
    }

    // MARK: - Skip vs Complete parity

    @Test func skipMidHoldCreditsTheSameInProgressHoldShape() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let lunge = insertPose("Low Lunge", primary: ["hips"], in: context)

        // Session A ends mid-hold via Complete; session B ends via Skip (which
        // lands in the very next hold, then Complete). Both credit the hold
        // they were in with the seconds actually held — same shape, same
        // step index, same label set as the partial seconds are not
        // fabricated beyond the hold length.
        let flowA = twoHoldFlow(fold, lunge)
        let (sessionA, _) = liveSession(flowA, exercise: fold, in: context)
        let hub = YogaFlowRunnerHub()
        hub.start(plan: flowA, session: sessionA, context: context)
        hub.complete(for: sessionA.id)

        let flowB = twoHoldFlow(fold, lunge)
        let (sessionB, weB) = liveSession(flowB, exercise: fold, in: context)
        hub.start(plan: flowB, session: sessionB, context: context)
        let runnerB = try #require(hub.runner(for: sessionB.id))
        runnerB.skip()
        hub.complete(for: sessionB.id)
        defer {
            hub.stop(for: sessionA.id)
            hub.stop(for: sessionB.id)
        }

        let splitsA = labeledSplits(sessionA)
        let splitsB = labeledSplits(sessionB)
        let firstA = try #require(splitsA.first)
        let firstB = try #require(splitsB.first)
        let secondB = try #require(splitsB.dropFirst().first)
        #expect(splitsA.count == 1)
        #expect(splitsB.count == 2)   // skipped hold partial + next hold's partial
        #expect(firstA.index == 0)
        #expect(firstB.index == 0)
        #expect(firstA.label == "Forward Fold")
        #expect(firstB.label == "Forward Fold")
        #expect(secondB.index == 1)
        #expect(secondB.label == "Low Lunge")
        for row in splitsA + splitsB {
            #expect(row.duration >= 1)
            #expect(row.duration <= 30)
        }

        // Completing immediately after a skip must not fabricate a phantom
        // hold for the just-started one beyond its actual (sub-1s) partial.
        YogaSessionCompletion.complete(
            session: sessionB,
            workoutExercise: weB,
            exercise: fold,
            context: context,
            endedAt: .now,
            useClockDuration: true
        )
        #expect(labeledSplits(sessionB).count == 2)
        #expect(sessionB.posesCompleted == 2)
        _ = container
    }

    // MARK: - Background/termination (no live runner)

    @Test func terminationReconcilesIdenticalAggregatesToSkipAndComplete() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let lunge = insertPose("Low Lunge", primary: ["hips"], in: context)
        let flow = twoHoldFlow(fold, lunge)

        // Fixed timestamps: hold 0 (Fold) skipped at t0+10; hold 1 (Lunge)
        // held until the class stops at t0+25 — 15s into its 30s hold.
        let t0 = Date(timeIntervalSince1970: 1_000_000)

        // Skip-then-complete session: both holds recorded by the runner.
        let (skipSession, weSkip) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        split("Forward Fold", index: 0, duration: 10, startedAt: t0,
              endedAt: t0.addingTimeInterval(10), session: skipSession, context: context)
        split("Low Lunge", index: 1, duration: 15, startedAt: t0.addingTimeInterval(10),
              endedAt: t0.addingTimeInterval(25), session: skipSession, context: context)
        YogaSessionCompletion.complete(
            session: skipSession, workoutExercise: weSkip, exercise: fold, context: context,
            endedAt: t0.addingTimeInterval(25), useClockDuration: true
        )

        // Termination session: the app died mid-hold-1; only hold 0 and the
        // runner's durable step checkpoint were persisted.
        let (termSession, weTerm) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        split("Forward Fold", index: 0, duration: 10, startedAt: t0,
              endedAt: t0.addingTimeInterval(10), session: termSession, context: context)
        checkpoint(session: termSession, stepIndex: 1, at: t0.addingTimeInterval(10))
        YogaSessionCompletion.complete(
            session: termSession, workoutExercise: weTerm, exercise: fold, context: context,
            endedAt: t0.addingTimeInterval(25), useClockDuration: true
        )

        // Identical splits, pose count, history, and exposure across exit paths.
        #expect(labeledSplits(skipSession) == labeledSplits(termSession))
        #expect(skipSession.posesCompleted == termSession.posesCompleted)
        #expect(skipSession.posesCompleted == 2)
        let skipHistory = YogaHistoryPresentation.poses(session: skipSession, plan: flow)
        let terminationHistory = YogaHistoryPresentation.poses(session: termSession, plan: flow)
        // Row identity belongs to each session's persisted split UUID. Compare
        // the user-visible pose semantics, not unrelated storage identities.
        #expect(skipHistory.map(\.name) == terminationHistory.map(\.name))
        #expect(skipHistory.map(\.durationSeconds) == terminationHistory.map(\.durationSeconds))
        #expect(skipHistory.map(\.sideDetail) == terminationHistory.map(\.sideDetail))
        #expect(YogaHistoryPresentation.poseCount(session: termSession, plan: flow) == 2)
        #expect(FlexibilityAnalytics.decodeExposure(skipSession.flexibilityExposureJSON)
            == FlexibilityAnalytics.decodeExposure(termSession.flexibilityExposureJSON))
        #expect(FlexibilityAnalytics.decodeExposure(termSession.flexibilityExposureJSON)
            == ["hamstrings": 10, "hips": 15])
        _ = container
    }

    @Test func terminationInsideFirstHoldReconcilesPartialFromLiveStart() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let flow = twoHoldFlow(fold, insertPose("Low Lunge", primary: ["hips"], in: context))
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        // App terminated 12s into the first 30s hold; the workout finished
        // later from the wrist with no live runner.
        let (session, workoutExercise) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        checkpoint(session: session, stepIndex: 0, at: t0)
        try context.save()

        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: fold,
            context: context,
            endedAt: t0.addingTimeInterval(12),
            useClockDuration: true
        )

        let recorded = labeledSplits(session)
        #expect(recorded.count == 1)
        #expect(recorded[0].index == 0)
        #expect(recorded[0].label == "Forward Fold")
        #expect(recorded[0].duration == 12)
        #expect(recorded[0].startedAt == t0)
        #expect(recorded[0].endedAt == t0.addingTimeInterval(12))
        #expect(session.posesCompleted == 1)
        #expect(YogaHistoryPresentation.poseCount(session: session, plan: flow) == 1)
        #expect(FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
            == ["hamstrings": 12])
        _ = container
    }

    @Test func terminationMidLeftHoldKeepsSideFoldAndExposureConsistent() throws {
        let (container, context) = try TestStore.make()
        let pigeon = insertPose("Pigeon Pose", primary: ["hips"], unilateral: true, in: context)
        var flow = YogaFlowPlan.singlePose(from: pigeon, style: .hatha)
        flow.voiceGuidanceEnabled = false
        // singlePose of a unilateral pose expands to [Left, Right] at run time.
        #expect(YogaFlowRunner.expand(flow).count == 2)

        let t0 = Date(timeIntervalSince1970: 4_000_000)
        let (session, workoutExercise) = liveSession(flow, exercise: pigeon, startedAt: t0, in: context)
        checkpoint(session: session, stepIndex: 0, at: t0)
        try context.save()
        // Terminated 20s into the Left hold; the Right never started.
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: pigeon,
            context: context,
            endedAt: t0.addingTimeInterval(20),
            useClockDuration: true
        )

        let recorded = labeledSplits(session)
        #expect(recorded.count == 1)
        #expect(recorded[0].label == "Pigeon Pose — Left")
        #expect(recorded[0].duration == 20)
        #expect(session.posesCompleted == 1)
        let history = YogaHistoryPresentation.poses(session: session, plan: flow)
        #expect(history.count == 1)
        #expect(history[0].name == "Pigeon Pose")
        #expect(history[0].sideDetail == "Left")
        #expect(history[0].durationSeconds == 20)
        #expect(FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
            == ["hips": 20])
        _ = container
    }

    // MARK: - Idempotency / conservative timestamps

    @Test func completionPipelineNeverDoublesARecordedHold() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let lunge = insertPose("Low Lunge", primary: ["hips"], in: context)
        let flow = twoHoldFlow(fold, lunge)
        let t0 = Date(timeIntervalSince1970: 3_000_000)

        // Natural finish: every step recorded; the user lingers on the
        // "Practice complete" screen for two minutes before finishing.
        let (finished, weFinished) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        split("Forward Fold", index: 0, duration: 30, startedAt: t0,
              endedAt: t0.addingTimeInterval(30), session: finished, context: context)
        split("Low Lunge", index: 1, duration: 30, startedAt: t0.addingTimeInterval(30),
              endedAt: t0.addingTimeInterval(60), session: finished, context: context)
        finished.posesCompleted = 2   // what finishFlow writes
        YogaSessionCompletion.complete(
            session: finished, workoutExercise: weFinished, exercise: fold, context: context,
            endedAt: t0.addingTimeInterval(180), useClockDuration: true
        )
        #expect(labeledSplits(finished).count == 2)
        #expect(finished.posesCompleted == 2)

        // Runner recorded the final partial moments before the pipeline ran
        // (gap far under the 1s minimum) — no extra hold may appear.
        let (recorded, weRecorded) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        split("Forward Fold", index: 0, duration: 30, startedAt: t0,
              endedAt: t0.addingTimeInterval(30), session: recorded, context: context)
        split("Low Lunge", index: 1, duration: 15, startedAt: t0.addingTimeInterval(30),
              endedAt: t0.addingTimeInterval(45), session: recorded, context: context)
        YogaSessionCompletion.complete(
            session: recorded, workoutExercise: weRecorded, exercise: fold, context: context,
            endedAt: t0.addingTimeInterval(45), useClockDuration: true
        )
        #expect(labeledSplits(recorded).count == 2)
        #expect(recorded.posesCompleted == 2)
        _ = container
    }

    @Test func completionWithoutCheckpointNeverInfersCreditFromWallClockGaps() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let flow = twoHoldFlow(fold, insertPose("Low Lunge", primary: ["hips"], in: context))
        let t0 = Date(timeIntervalSince1970: 6_000_000)
        let (session, workoutExercise) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        // The session's end predates the last recorded split's end (clock
        // skew / data anomaly): the wall-clock gap is negative, so no newest
        // hold can be credited — and nothing beyond it may be invented either.
        split("Forward Fold", index: 0, duration: 10, startedAt: t0,
              endedAt: t0.addingTimeInterval(10), session: session, context: context)
        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: fold,
            context: context,
            endedAt: t0.addingTimeInterval(5),
            useClockDuration: true
        )
        #expect(labeledSplits(session).count == 1)
        #expect(session.posesCompleted == 1)
        _ = container
    }

    @Test func pausedTerminationCreditsOnlyPrePauseHoldTime() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let flow = twoHoldFlow(fold, insertPose("Low Lunge", primary: ["hips"], in: context))
        let t0 = Date(timeIntervalSince1970: 7_000_000)
        let (session, workoutExercise) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        // Five seconds were held, then the class remained paused for 10
        // minutes before a Watch-initiated finish. Paused wall time is zero
        // credit, even though the session clock continued.
        checkpoint(
            session: session,
            stepIndex: 0,
            elapsed: 5,
            paused: true,
            at: t0.addingTimeInterval(5)
        )

        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: fold,
            context: context,
            endedAt: t0.addingTimeInterval(605),
            useClockDuration: true
        )

        let recorded = labeledSplits(session)
        #expect(recorded.count == 1)
        #expect(recorded[0].index == 0)
        #expect(recorded[0].duration == 5)
        #expect(FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
            == ["hamstrings": 5])
        _ = container
    }

    @Test func fullyRecordedRelaunchRestoresFinishedWithoutRepeatingSideEffects() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let lunge = insertPose("Low Lunge", primary: ["hips"], in: context)
        let flow = twoHoldFlow(fold, lunge)
        let t0 = Date(timeIntervalSince1970: 8_000_000)
        let (session, _) = liveSession(flow, exercise: fold, startedAt: t0, in: context)
        split("Forward Fold", index: 0, duration: 30, startedAt: t0,
              endedAt: t0.addingTimeInterval(30), session: session, context: context)
        split("Low Lunge", index: 1, duration: 30, startedAt: t0.addingTimeInterval(30),
              endedAt: t0.addingTimeInterval(60), session: session, context: context)
        session.posesCompleted = nil // crash window before finishFlow's marker write
        let historyBefore = UserDefaults.standard.data(forKey: YogaGuidanceCatalog.recentGuidanceKey)

        let hub = YogaFlowRunnerHub()
        hub.start(plan: flow, session: session, context: context)
        defer { hub.stop(for: session.id, clearCheckpoint: true) }

        let runner = try #require(hub.runner(for: session.id))
        #expect(runner.isFinished)
        #expect(runner.currentIndex == runner.steps.count)
        #expect(labeledSplits(session).count == 2)
        #expect(session.posesCompleted == nil)
        #expect(UserDefaults.standard.data(forKey: YogaGuidanceCatalog.recentGuidanceKey) == historyBefore)
        _ = container
    }

    // MARK: - Manual logs and stop-without-credit

    @Test func manualLogNeverGetsInterruptedHoldSplits() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let flow = twoHoldFlow(fold, insertPose("Low Lunge", primary: ["hips"], in: context))
        // Deliberate manual log: never live, nominal duration already set.
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: fold.id,
            yogaFlowJSON: flow.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: Date(timeIntervalSince1970: 5_000_000),
            sourceDevice: CardioSessionModel.yogaManualSource,
            durationSeconds: 60,
            yogaStyleRaw: YogaStyle.hatha.rawValue
        )
        context.insert(workoutExercise)
        context.insert(session)
        try context.save()

        YogaSessionCompletion.complete(
            session: session,
            workoutExercise: workoutExercise,
            exercise: fold,
            context: context,
            endedAt: Date(timeIntervalSince1970: 5_000_060),
            useClockDuration: false
        )

        // No interrupted-hold split for a log that never ran live; the
        // plan-scaled exposure (60s against a 60s nominal plan) still applies.
        #expect(labeledSplits(session).isEmpty)
        #expect(session.posesCompleted == nil)
        #expect(FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
            == ["hamstrings": 30, "hips": 30])
        _ = container
    }

    @Test func stopWithoutCreditIsNotACompletion() throws {
        let (container, context) = try TestStore.make()
        let fold = insertPose("Forward Fold", primary: ["hamstrings"], in: context)
        let flow = twoHoldFlow(fold, insertPose("Low Lunge", primary: ["hips"], in: context))
        let (session, _) = liveSession(flow, exercise: fold, in: context)
        try context.save()

        let hub = YogaFlowRunnerHub()
        hub.start(plan: flow, session: session, context: context)
        defer { hub.stop(for: session.id, clearCheckpoint: true) }

        // The removal/cancel path (delete block, discard workout) tears the
        // runner down without leaving partial credit in a session that is
        // going away — stop() must never act like a completion.
        hub.stop(for: session.id, clearCheckpoint: true)
        #expect(labeledSplits(session).isEmpty)
        #expect(hub.runner(for: session.id) == nil)
        _ = container
    }
}
