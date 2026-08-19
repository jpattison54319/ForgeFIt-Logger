import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct YogaPoseCountConsistencyTests {
    @Test func bilateralPoseUsesOneCountAcrossPresentationAnalyticsAndExports() {
        let userID = ForgeFitDemo.userID
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pose = ExerciseLibraryModel(
            id: UUID(),
            name: "Pigeon",
            modalityRaw: CardioSessionModel.yogaModality
        )
        let workoutExercise = WorkoutExerciseModel(userID: userID, exerciseID: pose.id)
        let session = CardioSessionModel(
            userID: userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            durationSeconds: 120,
            yogaStyleRaw: YogaStyle.yin.rawValue,
            posesCompleted: 2,
            splits: [
                split("Pigeon — Left", index: 0, start: start, userID: userID),
                split("Pigeon — Right", index: 1, start: start.addingTimeInterval(60), userID: userID)
            ]
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Yoga",
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            exercises: [workoutExercise],
            cardioSessions: [session]
        )

        #expect(session.logicalYogaPosesCompleted == 1)
        #expect(YogaHistoryPresentation.poseCount(session: session, plan: nil) == 1)

        let analytics = TrainingAnalytics(workouts: [workout], exercises: [pose], now: start.addingTimeInterval(300))
        #expect(analytics.yogaOverview(in: .all).poses == 1)

        let entries = CardioExerciseStats.entries(for: pose.id, in: [workout], isYoga: true)
        #expect(CardioExerciseStats.yogaRecords(entries: entries)
            .first(where: { $0.kind == .mostPoses })?.value == 1)
        #expect(CardioExerciseStats.yogaSummary(for: entries[0]).contains("1 pose"))

        let shared = SocialWorkoutMapper.shared(from: workout, exerciseNames: [pose.id: pose.name])
        #expect(shared.cardioSessions.first?.posesCompleted == 1)
        let backup = BackupMapper.backupWorkout(from: workout, exerciseNames: [pose.id: pose.name])
        #expect(backup.cardioSessions.first?.posesCompleted == 1)
    }

    private func split(
        _ label: String,
        index: Int,
        start: Date,
        userID: UUID
    ) -> CardioSplitModel {
        CardioSplitModel(
            userID: userID,
            cardioSessionID: UUID(),
            index: index,
            distanceMeters: 0,
            durationSeconds: 60,
            paceSecondsPerKm: 0,
            label: label,
            startedAt: start,
            endedAt: start.addingTimeInterval(60)
        )
    }
}
