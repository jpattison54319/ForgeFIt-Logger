import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// Yoga through the workout pipeline: factory session creation, XP award
/// shape, and the yoga/cardio split.
@MainActor
struct YogaWorkoutPipelineTests {

    private func makePose(name: String = "Pigeon Pose", hold: Int = 60, unilateral: Bool = true) -> ExerciseLibraryModel {
        let pose = ExerciseLibraryModel(name: name, modalityRaw: "yoga", defaultHoldSeconds: hold)
        pose.isUnilateral = unilateral
        return pose
    }

    // MARK: - Factory

    @Test func routineStartCreatesYogaSessionNotSets() throws {
        let (container, context) = try TestStore.make()
        let pose = makePose()
        context.insert(pose)

        let plan = YogaFlowPlan.singlePose(from: pose)
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Evening Stretch")
        let routineExercise = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: pose.id,
            yogaFlowJSON: plan.encodedJSON()
        )
        routine.exercises = [routineExercise]
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [pose], in: context)

        let we = try #require(workout.exercises.first)
        #expect(we.sets.isEmpty)
        #expect(we.yogaFlowJSON != nil)
        let session = try #require(workout.cardioSessions.first)
        #expect(session.isYogaSession)
        #expect(session.workoutExerciseID == we.id)
        // Unilateral single pose expands both sides: 2 × 60s.
        #expect(session.durationSeconds == 120)
        _ = container
    }

    @Test func routineStartSynthesizesFlowForBarePose() throws {
        let (container, context) = try TestStore.make()
        let pose = makePose(name: "Child's Pose", hold: 45, unilateral: false)
        context.insert(pose)

        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Wind Down")
        // No authored flow on the routine exercise.
        routine.exercises = [RoutineExerciseModel(userID: ForgeFitDemo.userID, exerciseID: pose.id)]
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [pose], in: context)

        let we = try #require(workout.exercises.first)
        let plan = try #require(YogaFlowPlan.decode(from: we.yogaFlowJSON))
        #expect(plan.steps.count == 1)
        #expect(plan.steps.first?.holdSeconds == 45)
        #expect(workout.cardioSessions.first?.durationSeconds == 45)
        _ = container
    }

    @Test func routineStartKeepsYogaSessionUnconfiguredUntilBuilt() throws {
        let (container, context) = try TestStore.make()
        let sessionExercise = YogaPoseCatalog.sessionExercise(in: context)

        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Choose Later")
        routine.exercises = [RoutineExerciseModel(userID: ForgeFitDemo.userID, exerciseID: sessionExercise.id)]
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [sessionExercise], in: context)

        let we = try #require(workout.exercises.first)
        #expect(we.exerciseID == YogaPoseCatalog.sessionExerciseID)
        #expect(we.sets.isEmpty)
        #expect(we.yogaFlowJSON == nil)
        let session = try #require(workout.cardioSessions.first)
        #expect(session.isYogaSession)
        #expect(session.durationSeconds == nil)
        _ = container
    }

    @Test func startYogaQuickStartAnchorsOnSessionCard() throws {
        let (container, context) = try TestStore.make()
        let pose = makePose(name: "Downward-Facing Dog", hold: 30, unilateral: false)
        context.insert(pose)
        try context.save()

        let flow = YogaFlowPlan.singlePose(from: pose, style: .vinyasa)
        let workout = WorkoutFactory.startYoga(flow: flow, named: "Morning Flow", exercises: [pose], in: context)

        #expect(workout.title == "Morning Flow")
        #expect(workout.exercises.first?.exerciseID == YogaPoseCatalog.sessionExerciseID)
        let session = try #require(workout.cardioSessions.first)
        #expect(session.isYogaSession)
        #expect(session.yogaStyleRaw == "vinyasa")
        _ = container
    }

    @Test func runnerHubResumesAtFirstIncompletePoseSplit() throws {
        let (container, context) = try TestStore.make()
        let first = makePose(name: "Forward Fold", hold: 30, unilateral: false)
        let second = makePose(name: "Low Lunge", hold: 30, unilateral: false)
        context.insert(first)
        context.insert(second)

        let plan = YogaFlowPlan(style: .hatha, steps: [
            YogaFlowPlan.PoseStep(poseID: first.id, name: first.name, holdSeconds: 30),
            YogaFlowPlan.PoseStep(poseID: second.id, name: second.name, holdSeconds: 30)
        ])
        let session = CardioSessionModel(userID: ForgeFitDemo.userID, modality: CardioSessionModel.yogaModality)
        let completed = CardioSplitModel(
            userID: ForgeFitDemo.userID,
            cardioSessionID: session.id,
            index: 0,
            distanceMeters: 0,
            durationSeconds: 30,
            paceSecondsPerKm: 0,
            label: "Forward Fold",
            startedAt: Date.now.addingTimeInterval(-30),
            endedAt: Date.now
        )
        completed.cardioSession = session
        session.splits = [completed]
        context.insert(session)
        context.insert(completed)
        try context.save()

        YogaFlowRunnerHub.shared.start(plan: plan, session: session, context: context)
        defer { YogaFlowRunnerHub.shared.stop(for: session.id) }

        let runner = try #require(YogaFlowRunnerHub.shared.runner(for: session.id))
        #expect(runner.currentIndex == 1)
        #expect(runner.currentStep?.displayName == "Low Lunge")
        _ = container
    }

    @Test func strengthRoutineStartIsUnchangedByYogaBranch() throws {
        let (container, context) = try TestStore.make()
        let bench = ExerciseLibraryModel(name: "Bench Press")
        context.insert(bench)

        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Push Day")
        let re = RoutineExerciseModel(userID: ForgeFitDemo.userID, exerciseID: bench.id)
        re.sets = [RoutineSetModel(userID: ForgeFitDemo.userID, position: 0, targetRepsLow: 8)]
        routine.exercises = [re]
        context.insert(routine)
        try context.save()

        let workout = WorkoutFactory.start(routine: routine, exercises: [bench], in: context)
        #expect(workout.exercises.first?.sets.count == 1)
        #expect(workout.cardioSessions.isEmpty)
        #expect(workout.exercises.first?.yogaFlowJSON == nil)
        _ = container
    }

    @Test func finishWorkoutCompletesManualYogaAndStampsExposure() throws {
        let (container, context) = try TestStore.make()
        let pose = makePose(name: "Butterfly", hold: 120, unilateral: false)
        pose.primaryMuscles = ["adductors"]
        context.insert(pose)

        let plan = YogaFlowPlan.singlePose(from: pose, style: .yin)
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: pose.id,
            yogaFlowJSON: plan.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: Date.now.addingTimeInterval(-600),
            // A deliberate manual log carries the editor's source marker —
            // an untouched planned block (no marker) is skipped at finish.
            sourceDevice: CardioSessionModel.yogaManualSource,
            durationSeconds: 300,
            yogaStyleRaw: YogaStyle.yin.rawValue
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Manual Yoga",
            startedAt: Date.now.addingTimeInterval(-600),
            exercises: [workoutExercise],
            cardioSessions: [session]
        )
        context.insert(workout)
        try context.save()

        WorkoutFinisher.finish(workout, in: context)

        #expect(workout.endedAt != nil)
        #expect(session.endedAt != nil)
        #expect(session.durationSeconds == 300)
        let exposure = FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
        #expect(exposure["adductors"] == 300)
        _ = container
    }

    @Test func finishWorkoutSkipsUntouchedYogaBlock() throws {
        let (container, context) = try TestStore.make()
        let pose = makePose(name: "Sphinx", hold: 60, unilateral: false)
        context.insert(pose)

        // A completed lift gives the workout real substance, so finish()
        // completes it rather than discarding it as empty. That's the case
        // that exercises the skip logic below: a mixed session (lifts + a yoga
        // cool-down) where the yoga block was never practiced must land in
        // history with the block left untouched — not auto-logged at its
        // planned length with phantom flexibility credit.
        let completedLift = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            position: 0,
            sets: [SetModel(userID: ForgeFitDemo.userID, position: 0, reps: 8, weight: 100, completedAt: .now)]
        )

        let plan = YogaFlowPlan.singlePose(from: pose)
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: pose.id,
            position: 1,
            yogaFlowJSON: plan.encodedJSON()
        )
        // Factory-shaped session: plan duration as target, never started,
        // never manually edited.
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: Date.now.addingTimeInterval(-600),
            durationSeconds: plan.totalSeconds,
            yogaStyleRaw: plan.styleRaw
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Lift, then skipped yoga",
            startedAt: Date.now.addingTimeInterval(-600),
            exercises: [completedLift, workoutExercise],
            cardioSessions: [session]
        )
        context.insert(workout)
        try context.save()

        WorkoutFinisher.finish(workout, in: context)

        // The lift's substance completes the workout — it isn't discarded.
        #expect(workout.endedAt != nil)
        #expect(workout.deletedAt == nil)
        // The un-practiced block stays incomplete: no exposure, no pose count.
        #expect(session.endedAt == nil)
        #expect(session.flexibilityExposureJSON == nil)
        _ = container
    }

    // MARK: - XP

    private func yogaWorkout(seconds: Int, style: YogaStyle, ended: Bool = true) -> WorkoutModel {
        let start = Date(timeIntervalSinceNow: -Double(seconds) - 60)
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            durationSeconds: seconds,
            yogaStyleRaw: style.rawValue
        )
        return WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Yoga",
            startedAt: start,
            endedAt: ended ? Date() : nil,
            cardioSessions: [session]
        )
    }

    @Test func yogaSessionEarnsYogaXPNotCardioXP() {
        let award = XPService.previewAward(for: yogaWorkout(seconds: 1800, style: .vinyasa))
        #expect(award.eligible)
        #expect(award.cardioDuration == 0)
        #expect(award.cardioDistance == 0)
        // 30min active yoga at the cardio rate: 30 × 1.2 = 36.
        #expect(award.yogaDuration == 36)
    }

    @Test func restorativeYogaEarnsHalfRate() {
        let award = XPService.previewAward(for: yogaWorkout(seconds: 1800, style: .restorative))
        #expect(award.eligible)
        // 30min restorative: 30 × 0.6 = 18.
        #expect(award.yogaDuration == 18)
    }

    @Test func shortYogaSessionIsNotEligible() {
        let award = XPService.previewAward(for: yogaWorkout(seconds: 200, style: .vinyasa))
        #expect(!award.eligible)
        #expect(award.amount == 0)
    }

    @Test func cardioXPUnchangedByYogaComponent() {
        let start = Date(timeIntervalSinceNow: -2000)
        let run = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: "run",
            startedAt: start,
            durationSeconds: 1800,
            distanceMeters: 5000
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Run",
            startedAt: start,
            endedAt: Date(),
            cardioSessions: [run]
        )
        let award = XPService.previewAward(for: workout)
        #expect(award.eligible)
        #expect(award.cardioDuration == 36)
        #expect(award.cardioDistance == 20)
        #expect(award.yogaDuration == 0)
    }
}
