import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// The flexibility pillar's exposure math: per-region seconds from guided
/// splits (label-matched) and manual fallback scaling.
@MainActor
struct FlexibilityAnalyticsTests {

    /// A custom pose row so region lookup exercises the library path.
    private func insertPose(
        _ name: String,
        primary: [String],
        secondary: [String] = [],
        unilateral: Bool = false,
        in context: ModelContext
    ) -> ExerciseLibraryModel {
        let pose = ExerciseLibraryModel(name: name, modalityRaw: "yoga", defaultHoldSeconds: 30)
        pose.primaryMuscles = primary
        pose.secondaryMuscles = secondary
        pose.isUnilateral = unilateral
        context.insert(pose)
        return pose
    }

    private func split(_ label: String, seconds: Int, index: Int, session: CardioSessionModel, context: ModelContext) {
        let split = CardioSplitModel(
            userID: session.userID,
            cardioSessionID: session.id,
            index: index,
            distanceMeters: 0,
            durationSeconds: seconds,
            paceSecondsPerKm: 0,
            label: label,
            startedAt: Date(),
            endedAt: Date()
        )
        split.cardioSession = session
        context.insert(split)
        session.splits.append(split)
    }

    @Test func guidedExposureCreditsActualHoldsByLabel() throws {
        let (container, context) = try TestStore.make()
        let hamstrings = insertPose("Forward Fold", primary: ["hamstrings"], secondary: ["lower back"], in: context)
        let hips = insertPose("Deep Squat Hold", primary: ["hips"], unilateral: true, in: context)

        let plan = YogaFlowPlan(style: .hatha, steps: [
            YogaFlowPlan.PoseStep(poseID: hamstrings.id, name: "Forward Fold", holdSeconds: 60),
            YogaFlowPlan.PoseStep(poseID: hips.id, name: "Deep Squat Hold", holdSeconds: 45, side: .bothSides)
        ])
        let session = CardioSessionModel(userID: ForgeFitDemo.userID, modality: "yoga")
        context.insert(session)
        try context.save()

        // Guided run: fold held short (40s), both squat sides held full.
        split("Forward Fold", seconds: 40, index: 0, session: session, context: context)
        split("Deep Squat Hold — Left", seconds: 45, index: 1, session: session, context: context)
        split("Deep Squat Hold — Right", seconds: 45, index: 2, session: session, context: context)
        try context.save()

        let exposure = FlexibilityAnalytics.exposure(plan: plan, session: session, context: context)
        #expect(exposure["hamstrings"] == 40)
        #expect(exposure["lower back"] == 20)      // secondary = half credit
        #expect(exposure["hips"] == 90)            // both sides
        _ = container
    }

    @Test func manualLogScalesPlanToLoggedDuration() throws {
        let (container, context) = try TestStore.make()
        let pose = insertPose("Butterfly", primary: ["adductors"], in: context)
        let plan = YogaFlowPlan(style: .yin, steps: [
            YogaFlowPlan.PoseStep(poseID: pose.id, name: "Butterfly", holdSeconds: 120)
        ])
        // Logged manually for 60s against a nominal 120s plan → half credit.
        let session = CardioSessionModel(userID: ForgeFitDemo.userID, modality: "yoga", durationSeconds: 60)
        context.insert(session)
        try context.save()

        let exposure = FlexibilityAnalytics.exposure(plan: plan, session: session, context: context)
        #expect(exposure["adductors"] == 60)
        _ = container
    }

    @Test func stampExposureFreezesSnapshotOnSession() throws {
        let (container, context) = try TestStore.make()
        let pose = insertPose("Sphinx", primary: ["spine"], in: context)
        let plan = YogaFlowPlan(style: .gentle, steps: [
            YogaFlowPlan.PoseStep(poseID: pose.id, name: "Sphinx", holdSeconds: 60)
        ])
        let session = CardioSessionModel(userID: ForgeFitDemo.userID, modality: "yoga", durationSeconds: 60)
        context.insert(session)
        try context.save()

        FlexibilityAnalytics.stampExposure(plan: plan, session: session, context: context)
        let decoded = FlexibilityAnalytics.decodeExposure(session.flexibilityExposureJSON)
        #expect(decoded["spine"] == 60)
        _ = container
    }

    @Test func regionSecondsAggregatesYogaAndStretchingSets() throws {
        let (container, context) = try TestStore.make()
        // Pinned mid-day: the fixtures sit "an hour ago" and the assertions
        // require one calendar day — a live `Date()` made that false (and the
        // test flaky) for the first hour after midnight.
        let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

        // A finished yoga workout with a frozen exposure snapshot.
        let yogaSession = CardioSessionModel(userID: ForgeFitDemo.userID, modality: "yoga", durationSeconds: 300)
        yogaSession.flexibilityExposureJSON = #"{"hips":300}"#
        let yogaWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID, startedAt: now.addingTimeInterval(-3600),
            endedAt: now.addingTimeInterval(-3000), cardioSessions: [yogaSession]
        )

        // A stretching-category exercise with a timed completed set.
        let stretch = ExerciseLibraryModel(name: "90/90 Hamstring")
        stretch.category = "stretching"
        stretch.primaryMuscles = ["hamstrings"]
        let set = SetModel(userID: ForgeFitDemo.userID, durationSeconds: 90, completedAt: now.addingTimeInterval(-500))
        let we = WorkoutExerciseModel(userID: ForgeFitDemo.userID, exerciseID: stretch.id, sets: [set])
        let stretchWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID, startedAt: now.addingTimeInterval(-1000),
            endedAt: now.addingTimeInterval(-400), exercises: [we]
        )
        context.insert(stretch)
        context.insert(yogaWorkout)
        context.insert(stretchWorkout)
        try context.save()

        let regions = FlexibilityAnalytics.regionSeconds(
            workouts: [yogaWorkout, stretchWorkout],
            exercises: [stretch],
            range: now.addingTimeInterval(-7200)...now
        )
        #expect(regions.first { $0.region == "hips" }?.seconds == 300)
        #expect(regions.first { $0.region == "hamstrings" }?.seconds == 90)

        let days = FlexibilityAnalytics.sessionDays(
            workouts: [yogaWorkout, stretchWorkout],
            exercises: [stretch],
            range: now.addingTimeInterval(-7200)...now
        )
        #expect(days == 1)   // same calendar day
        _ = container
    }
}
