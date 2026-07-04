import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct PersonalRecordsTests {
    private let userID = ForgeFitDemo.userID
    private let exerciseID = UUID(uuidString: "00000000-0000-7000-8000-00000000AA01")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstEverSessionEarnsNoAwards() {
        let workout = workout(daysAgo: 0)
        let set = completedSet(weight: 100, reps: 5, at: start)

        let baselines = PersonalRecords.baselines(history: [], before: workout)
        let awards = PersonalRecords.awards(for: set, baseline: baselines[exerciseID], sessionSets: [set])

        #expect(awards.isEmpty)
    }

    @Test func beatingHistoryAwardsAllThreeRecords() {
        let prior = workout(daysAgo: 7, sets: [priorSet(weight: 100, reps: 5)])
        let current = workout(daysAgo: 0)
        let set = completedSet(weight: 110, reps: 6, at: start)

        let baselines = PersonalRecords.baselines(history: [prior], before: current)
        let awards = PersonalRecords.awards(for: set, baseline: baselines[exerciseID], sessionSets: [set])

        #expect(awards.contains(.heaviestWeight))
        #expect(awards.contains(.bestSetVolume))
        #expect(awards.contains(.best1RM))
    }

    @Test func matchingHistoryIsNotARecord() {
        let prior = workout(daysAgo: 7, sets: [priorSet(weight: 100, reps: 5)])
        let current = workout(daysAgo: 0)
        let set = completedSet(weight: 100, reps: 5, at: start)

        let baselines = PersonalRecords.baselines(history: [prior], before: current)
        let awards = PersonalRecords.awards(for: set, baseline: baselines[exerciseID], sessionSets: [set])

        #expect(awards.isEmpty)
    }

    @Test func laterSetMustBeatEarlierSessionAward() {
        let prior = workout(daysAgo: 7, sets: [priorSet(weight: 100, reps: 5)])
        let current = workout(daysAgo: 0)
        let first = completedSet(weight: 110, reps: 5, at: start)
        let second = completedSet(weight: 105, reps: 5, at: start.addingTimeInterval(120))
        let session = [first, second]

        let baselines = PersonalRecords.baselines(history: [prior], before: current)
        let firstAwards = PersonalRecords.awards(for: first, baseline: baselines[exerciseID], sessionSets: session)
        let secondAwards = PersonalRecords.awards(for: second, baseline: baselines[exerciseID], sessionSets: session)

        #expect(firstAwards.contains(.heaviestWeight))
        #expect(!secondAwards.contains(.heaviestWeight))
    }

    @Test func warmupAndDeletedWorkoutsAreIgnored() {
        let deleted = workout(daysAgo: 7, sets: [priorSet(weight: 200, reps: 5)])
        deleted.deletedAt = start
        let warmupOnly = workout(daysAgo: 5, sets: [priorSet(weight: 180, reps: 5, type: .warmup)])
        let current = workout(daysAgo: 0)

        let baselines = PersonalRecords.baselines(history: [deleted, warmupOnly], before: current)

        // Neither source counts, so there is no history and no bar to clear.
        #expect(baselines[exerciseID]?.hasHistory != true)
    }

    @Test func summaryPicksTheSingleBestSetPerKind() {
        let prior = workout(daysAgo: 7, sets: [priorSet(weight: 100, reps: 5)])
        let current = workout(daysAgo: 0, sets: [
            completedSet(weight: 105, reps: 5, at: start),
            completedSet(weight: 115, reps: 5, at: start.addingTimeInterval(120)),
        ])

        let baselines = PersonalRecords.baselines(history: [prior], before: current)
        let awards = PersonalRecords.summaryAwards(for: current.exercises[0], baseline: baselines[exerciseID])

        let heaviest = awards.first { $0.kind == .heaviestWeight }
        #expect(heaviest?.set.weight == 115)
    }

    @Test func allTimeBestsSpanEveryWorkoutIncludingActive() {
        let old = workout(daysAgo: 14, sets: [priorSet(weight: 120, reps: 3)])
        let active = workout(daysAgo: 0, sets: [completedSet(weight: 110, reps: 10, at: start)])
        active.endedAt = nil // still in progress — its sets still count

        let bests = PersonalRecords.allTimeBests(for: exerciseID, in: [old, active])

        #expect(bests.first { $0.kind == .heaviestWeight }?.set.weight == 120)
        // 110×10 = 1100 beats 120×3 = 360.
        #expect(bests.first { $0.kind == .bestSetVolume }?.set.weight == 110)
        // Epley: 110×(1+10/30) ≈ 146 beats 120×(1+3/30) = 132.
        #expect(bests.first { $0.kind == .best1RM }?.set.weight == 110)
    }

    // MARK: - Fixtures

    private func workout(daysAgo: Int, sets: [SetModel] = []) -> WorkoutModel {
        let started = start.addingTimeInterval(-Double(daysAgo) * 86_400)
        let workout = WorkoutModel(
            userID: userID,
            startedAt: started,
            endedAt: started.addingTimeInterval(3_600),
            sourceDevice: "iphone"
        )
        if !sets.isEmpty {
            let we = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, position: 0, sets: sets)
            workout.exercises = [we]
        }
        return workout
    }

    private func priorSet(weight: Double, reps: Int, type: SetType = .working) -> SetModel {
        SetModel(userID: userID, setType: type, reps: reps, weight: weight, completedAt: start.addingTimeInterval(-6 * 86_400))
    }

    private func completedSet(weight: Double, reps: Int, at date: Date) -> SetModel {
        SetModel(userID: userID, reps: reps, weight: weight, completedAt: date)
    }
}
