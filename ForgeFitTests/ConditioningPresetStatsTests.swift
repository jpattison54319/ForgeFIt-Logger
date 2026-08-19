import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct ConditioningPresetStatsTests {
    private let userID = ForgeFitDemo.userID
    private let movementID = UUID(uuidString: "00000000-0000-7000-8000-00000000C101")!
    private let start = Date(timeIntervalSince1970: 1_800_100_000)

    @Test func exactPrescriptionHistoryIgnoresNamesButNotChangedWork() {
        let target = section(name: "100s Chipper", rounds: 10)
        let renamed = section(name: "Garage Chipper", rounds: 10)
        let changed = section(name: "100s Chipper", rounds: 12)
        let workouts = [
            workout(at: start, section: target, elapsed: 700),
            workout(at: start.addingTimeInterval(-86_400), section: renamed, elapsed: 740),
            workout(at: start.addingTimeInterval(-172_800), section: changed, elapsed: 680),
        ]

        let entries = ConditioningPresetStats.entries(for: target, in: workouts)

        #expect(entries.count == 2)
        #expect(entries.map(\.result.elapsedSeconds) == [700, 740])
    }

    @Test func performanceTrendExcludesIncompleteAttemptButHistoryRetainsIt() {
        let target = section(name: "100s Chipper", rounds: 10)
        let workouts = [
            workout(at: start, section: target, elapsed: 700),
            workout(
                at: start.addingTimeInterval(-86_400),
                section: target,
                elapsed: 900,
                completedRounds: 7,
                completed: false
            ),
            workout(at: start.addingTimeInterval(-172_800), section: target, elapsed: 800),
        ]

        let entries = ConditioningPresetStats.entries(for: target, in: workouts)
        let performance = ConditioningPresetStats.series(.performance, for: target, entries: entries)
        let completion = ConditioningPresetStats.series(.completion, for: target, entries: entries)

        #expect(entries.count == 3)
        #expect(performance.map(\.value) == [800, 700])
        #expect(completion.map(\.value) == [100, 70, 100])
        #expect(ConditioningPresetStats.availableMetrics(for: target, entries: entries).contains(.completion))
    }

    @Test func pacingMetricsUseSavedRoundCheckpoints() throws {
        let target = section(name: "Four rounds", rounds: 4)
        let logged = workout(
            at: start,
            section: target,
            elapsed: 470,
            completedRounds: 4,
            totalReps: 40,
            completions: [100, 210, 330, 470]
        )
        let entry = try #require(ConditioningPresetStats.entries(for: target, in: [logged]).first)

        #expect(ConditioningPresetStats.value(.averageRound, entry: entry, target: target) == 118)
        #expect(ConditioningPresetStats.value(.fastestRound, entry: entry, target: target) == 100)
        #expect(ConditioningPresetStats.value(.repRate, entry: entry, target: target) == 40.0 * 60 / 470.0)
        #expect(abs((ConditioningPresetStats.value(.secondHalfChange, entry: entry, target: target) ?? 0) - 23.8095) < 0.001)
    }

    @Test func blockSnapshotHistoryIsIncludedAlongsideLegacyHistory() {
        let target = section(name: "Block Chipper", rounds: 10)
        let result = result(section: target, elapsed: 710)
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            planSnapshotJSON: ConditioningPlan(sections: [target]).encodedJSON(),
            resultJSON: ConditioningResult(sectionResults: [result]).encodedJSON()
        )
        let blockWorkout = WorkoutModel(
            userID: userID,
            title: "Block workout",
            startedAt: start,
            endedAt: start.addingTimeInterval(710),
            blocks: [block]
        )
        let legacyWorkout = workout(
            at: start.addingTimeInterval(-86_400),
            section: target,
            elapsed: 730
        )

        let entries = ConditioningPresetStats.entries(
            for: target,
            in: [blockWorkout, legacyWorkout]
        )

        #expect(entries.map(\.result.elapsedSeconds) == [710, 730])
    }

    private func section(name: String, rounds: Int) -> ConditioningSection {
        ConditioningSection(
            name: name,
            format: .forTime,
            scoreKind: .elapsedTime,
            rounds: rounds,
            movements: [ConditioningMovement(exerciseID: movementID, targetValue: 10)]
        )
    }

    private func workout(
        at date: Date,
        section: ConditioningSection,
        elapsed: Int,
        completedRounds: Int? = nil,
        totalReps: Int? = nil,
        completions: [Int]? = nil,
        completed: Bool = true
    ) -> WorkoutModel {
        let sectionResult = result(
            section: section,
            elapsed: elapsed,
            completedRounds: completedRounds,
            totalReps: totalReps,
            completions: completions,
            completed: completed
        )
        return WorkoutModel(
            userID: userID,
            title: section.name,
            startedAt: date,
            endedAt: date.addingTimeInterval(TimeInterval(elapsed)),
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            conditioningResultJSON: ConditioningResult(sectionResults: [sectionResult]).encodedJSON()
        )
    }

    private func result(
        section: ConditioningSection,
        elapsed: Int,
        completedRounds: Int? = nil,
        totalReps: Int? = nil,
        completions: [Int]? = nil,
        completed: Bool = true
    ) -> ConditioningSectionResult {
        ConditioningSectionResult(
            id: section.id,
            format: section.format,
            scoreKind: section.scoreKind,
            elapsedSeconds: elapsed,
            fullRounds: completedRounds ?? section.prescribedRounds,
            totalReps: totalReps,
            roundCompletionElapsedSeconds: completions,
            completed: completed
        )
    }
}
