import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutAwardsTests {
    private let userID = ForgeFitDemo.userID
    private let movementID = UUID(uuidString: "00000000-0000-7000-8000-00000000C001")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstConditioningResultEstablishesBaselineWithoutAward() {
        let workout = conditioningWorkout(
            startedAt: start,
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 720
        )

        let awards = WorkoutAwards.modalityAwards(for: workout, history: [])

        #expect(awards.isEmpty)
    }

    @Test func fasterExactConditioningPrescriptionEarnsBestTime() {
        let prior = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: forTimeSection(name: "Old Chipper Name", rounds: 10),
            elapsedSeconds: 720
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 660
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        let bestTime = awards.first { $0.kind == .conditioningBestTime }
        #expect(bestTime?.title == "100s Chipper")
        #expect(bestTime?.valueText == "11:00")
    }

    @Test func changedConditioningWorkStartsNewBaseline() {
        let prior = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 720
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: forTimeSection(name: "100s Chipper", rounds: 20),
            elapsedSeconds: 660
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        #expect(!awards.contains { $0.kind == .conditioningBestTime })
    }

    @Test func amrapMoreWorkEarnsBestScore() {
        let priorSection = amrapSection()
        let currentSection = amrapSection()
        let prior = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: priorSection,
            elapsedSeconds: 600,
            fullRounds: 8,
            totalReps: 80
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: currentSection,
            elapsedSeconds: 600,
            fullRounds: 9,
            totalReps: 90
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        #expect(awards.contains {
            $0.kind == .conditioningBestScore && $0.valueText == "9 rounds · 90 reps"
        })
        #expect(!awards.contains { $0.kind == .conditioningBestTime })
    }

    @Test func incompleteConditioningResultCannotSetOrWinARecord() {
        let incomplete = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 600,
            completed: false
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 660
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [incomplete])

        #expect(!awards.contains { $0.kind == .conditioningBestTime })
    }

    @Test func matchingSectionsInFirstWorkoutDoNotCompeteWithEachOther() {
        let firstSection = forTimeSection(name: "Chipper A", rounds: 10)
        let secondSection = forTimeSection(name: "Chipper B", rounds: 10)
        let workout = WorkoutModel(
            userID: userID,
            title: "Double Chipper",
            startedAt: start,
            endedAt: start.addingTimeInterval(1_380),
            conditioningPlanSnapshotJSON: ConditioningPlan(
                sections: [firstSection, secondSection]
            ).encodedJSON(),
            conditioningResultJSON: ConditioningResult(sectionResults: [
                conditioningResult(section: firstSection, elapsedSeconds: 720),
                conditioningResult(section: secondSection, elapsedSeconds: 660),
            ]).encodedJSON()
        )

        let awards = WorkoutAwards.modalityAwards(for: workout, history: [])

        #expect(awards.isEmpty)
    }

    @Test func fasterRoundCanEarnAwardWithoutBestOverallTime() {
        let prior = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: forTimeSection(name: "Six rounds", rounds: 6),
            elapsedSeconds: 600,
            fullRounds: 6,
            completions: [100, 200, 300, 400, 500, 600]
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: forTimeSection(name: "Six rounds", rounds: 6),
            elapsedSeconds: 650,
            fullRounds: 6,
            completions: [90, 210, 320, 430, 540, 650]
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        #expect(awards.contains { $0.kind == .conditioningFastestRound && $0.valueText == "1:30" })
        #expect(!awards.contains { $0.kind == .conditioningBestTime })
    }

    @Test func heavierMaxLoadEarnsBestLoad() {
        let priorSection = maxLoadSection()
        let currentSection = maxLoadSection()
        let prior = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: priorSection,
            elapsedSeconds: 600,
            load: 100
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: currentSection,
            elapsedSeconds: 600,
            load: 110
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        #expect(awards.contains { $0.kind == .conditioningBestLoad })
    }

    @Test func yogaRewardsProgressWithinTheSameStyle() {
        let prior = yogaWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            style: .yin,
            durationSeconds: 900,
            poses: 7
        )
        let current = yogaWorkout(
            startedAt: start,
            style: .yin,
            durationSeconds: 1_200,
            poses: 10
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        #expect(awards.contains {
            $0.kind == .yogaLongestPractice && $0.title == "Yin Yoga" && $0.valueText == "20min"
        })
        #expect(awards.contains { $0.kind == .yogaMostPoses && $0.valueText == "10 poses" })
    }

    @Test func newYogaStyleEstablishesItsOwnBaseline() {
        let prior = yogaWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            style: .yin,
            durationSeconds: 900,
            poses: 7
        )
        let current = yogaWorkout(
            startedAt: start,
            style: .power,
            durationSeconds: 1_200,
            poses: 10
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [prior])

        #expect(!awards.contains { $0.kind == .yogaLongestPractice || $0.kind == .yogaMostPoses })
    }

    @Test func thirdConsecutiveYogaDayEarnsStreakAward() {
        let first = yogaWorkout(
            startedAt: start.addingTimeInterval(-2 * 86_400),
            style: .hatha,
            durationSeconds: 300,
            poses: 3
        )
        let second = yogaWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            style: .hatha,
            durationSeconds: 300,
            poses: 3
        )
        let current = yogaWorkout(
            startedAt: start,
            style: .hatha,
            durationSeconds: 300,
            poses: 3
        )

        let awards = WorkoutAwards.modalityAwards(for: current, history: [first, second])

        #expect(awards.contains { $0.kind == .yogaStreak && $0.valueText == "3 days" })
    }

    @Test func conditioningAwardIsIncludedInHistoryPRIndex() async {
        let prior = conditioningWorkout(
            startedAt: start.addingTimeInterval(-86_400),
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 720
        )
        let current = conditioningWorkout(
            startedAt: start,
            section: forTimeSection(name: "100s Chipper", rounds: 10),
            elapsedSeconds: 660
        )

        let index = await WorkoutHistoryIndexer.build(workouts: [current, prior], exercises: [])
        let currentEntry = index.entries.first { $0.id == current.id }

        #expect(currentEntry?.prCount == 1)
        #expect(currentEntry?.searchText.contains("best time") == true)
    }

    private func forTimeSection(name: String, rounds: Int) -> ConditioningSection {
        ConditioningSection(
            name: name,
            format: .forTime,
            scoreKind: .elapsedTime,
            rounds: rounds,
            movements: [ConditioningMovement(exerciseID: movementID, targetValue: 10)]
        )
    }

    private func amrapSection() -> ConditioningSection {
        ConditioningSection(
            name: "Ten-minute AMRAP",
            format: .amrap,
            scoreKind: .roundsAndReps,
            durationSeconds: 600,
            movements: [ConditioningMovement(exerciseID: movementID, targetValue: 10)]
        )
    }

    private func maxLoadSection() -> ConditioningSection {
        ConditioningSection(
            name: "Clean complex",
            format: .maxLoad,
            scoreKind: .load,
            rounds: 5,
            movements: [ConditioningMovement(exerciseID: movementID, targetValue: 1)]
        )
    }

    private func conditioningWorkout(
        startedAt: Date,
        section: ConditioningSection,
        elapsedSeconds: Int,
        fullRounds: Int? = nil,
        totalReps: Int? = nil,
        completions: [Int]? = nil,
        load: Double? = nil,
        completed: Bool = true
    ) -> WorkoutModel {
        let result = ConditioningResult(sectionResults: [
            conditioningResult(
                section: section,
                elapsedSeconds: elapsedSeconds,
                fullRounds: fullRounds,
                totalReps: totalReps,
                completions: completions,
                load: load,
                completed: completed
            )
        ])
        return WorkoutModel(
            userID: userID,
            title: section.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(TimeInterval(elapsedSeconds)),
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            conditioningResultJSON: result.encodedJSON()
        )
    }

    private func conditioningResult(
        section: ConditioningSection,
        elapsedSeconds: Int,
        fullRounds: Int? = nil,
        totalReps: Int? = nil,
        completions: [Int]? = nil,
        load: Double? = nil,
        completed: Bool = true
    ) -> ConditioningSectionResult {
        ConditioningSectionResult(
            id: section.id,
            format: section.format,
            scoreKind: section.scoreKind,
            elapsedSeconds: elapsedSeconds,
            fullRounds: fullRounds ?? section.prescribedRounds,
            totalReps: totalReps,
            load: load,
            roundCompletionElapsedSeconds: completions,
            completed: completed
        )
    }

    private func yogaWorkout(
        startedAt: Date,
        style: YogaStyle,
        durationSeconds: Int,
        poses: Int
    ) -> WorkoutModel {
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: startedAt,
            liveStartedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
            sourceDevice: CardioSessionModel.yogaManualSource,
            durationSeconds: durationSeconds,
            yogaStyleRaw: style.rawValue,
            posesCompleted: poses
        )
        return WorkoutModel(
            userID: userID,
            title: "\(style.title) Yoga",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(TimeInterval(durationSeconds)),
            cardioSessions: [session]
        )
    }
}
