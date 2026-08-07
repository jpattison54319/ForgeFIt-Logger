import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct LiveSetCompletionTests {
    private let userID = ForgeFitDemo.userID
    private let exerciseID = UUID(uuidString: "00000000-0000-7000-8000-00000000CC01")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func assistedRecordIsAvailableOnTheCompletionRefresh() {
        let priorSet = SetModel(
            userID: userID,
            weightMode: .bodyweightAssisted,
            reps: 10,
            assistanceWeight: 25,
            bodyweightKg: 80,
            completedAt: now.addingTimeInterval(-86_400)
        )
        let prior = workout(startedAt: now.addingTimeInterval(-86_400), set: priorSet)
        let current = workout(startedAt: now)
        current.endedAt = nil
        let currentSet = SetModel(
            userID: userID,
            weightMode: .bodyweightAssisted,
            reps: 9,
            assistanceWeight: 20
        )
        current.exercises = [
            WorkoutExerciseModel(
                userID: userID,
                exerciseID: exerciseID,
                position: 0,
                sets: [currentSet]
            )
        ]

        let baseline = PersonalRecords.baselines(history: [prior], before: current)[exerciseID]
        LiveSetCompletion.prepare(currentSet, completedAt: now, latestBodyweight: 80)
        let awards = PersonalRecords.awards(
            for: currentSet,
            baseline: baseline,
            sessionSets: [currentSet]
        )

        #expect(currentSet.effectiveLoad == 60)
        #expect(awards.contains(.heaviestWeight))
        #expect(awards.contains(.best1RM))
    }

    @Test func completionDoesNotReplaceTheSetsHistoricalBodyweightSnapshot() {
        let set = SetModel(
            userID: userID,
            weightMode: .bodyweightAssisted,
            reps: 8,
            assistanceWeight: 20,
            bodyweightKg: 79
        )

        LiveSetCompletion.prepare(set, completedAt: now, latestBodyweight: 82)

        #expect(set.bodyweightKg == 79)
        #expect(set.effectiveLoad == 59)
    }

    private func workout(startedAt: Date, set: SetModel? = nil) -> WorkoutModel {
        let workout = WorkoutModel(
            userID: userID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_600),
            sourceDevice: "iphone"
        )
        if let set {
            workout.exercises = [
                WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: exerciseID,
                    position: 0,
                    sets: [set]
                )
            ]
        }
        return workout
    }
}
