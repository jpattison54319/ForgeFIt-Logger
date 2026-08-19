import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct HomeWeekMetricsTests {
    private let userID = ForgeFitDemo.userID

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private var now: Date { date(2026, 8, 12, hour: 18) }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func exercise(_ name: String, modality: Modality) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            name: name,
            isCardio: modality == .cardio,
            modalityRaw: modality.rawValue
        )
    }

    private func workout(
        start: Date,
        duration: Int,
        exercises: [WorkoutExerciseModel] = [],
        sessions: [CardioSessionModel] = [],
        blocks: [WorkoutBlockModel] = [],
        averageHeartRate: Int? = nil
    ) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(duration)),
            avgHR: averageHeartRate,
            exercises: exercises,
            cardioSessions: sessions,
            blocks: blocks
        )
    }

    private func kinds(_ summary: HomeWeekMetrics.Summary) -> [HomeWeekMetrics.Metric.Kind] {
        summary.metrics.map(\.kind)
    }

    @Test func strengthOnlyWeekUsesFourStrengthRelevantHeadlines() {
        let library = exercise("Back Squat", modality: .strength)
        let completed = SetModel(
            userID: userID,
            reps: 10,
            weight: 100,
            completedAt: date(2026, 8, 10, hour: 10)
        )
        let row = WorkoutExerciseModel(
            userID: userID,
            exerciseID: library.id,
            sets: [completed]
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [workout(start: date(2026, 8, 10, hour: 9), duration: 3_600, exercises: [row])],
            exercises: [library],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time, .strengthVolume, .strengthSets, .strengthReps])
        #expect(summary.metrics.count == 4)
    }

    @Test func cardioUsesDistanceElevationAndCoveredHeartRate() throws {
        let start = date(2026, 8, 11, hour: 7)
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            durationSeconds: 1_800,
            distanceMeters: 5_000,
            avgHR: 150,
            elevationGainMeters: 120
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [workout(
                start: start,
                duration: 1_800,
                sessions: [session],
                averageHeartRate: 150
            )],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time, .cardioDistance, .cardioElevation, .averageHeartRate])
        let distance = try #require(summary.metrics.first { $0.kind == .cardioDistance })
        #expect(distance.formatted(weightUnit: .kg, distanceUnit: .mi) == "3.11 mi")
    }

    @Test func allSwimDistanceKeepsFixedMeters() throws {
        let start = date(2026, 8, 10, hour: 6)
        let swim = CardioSessionModel(
            userID: userID,
            modality: CardioKind.swim.rawValue,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_200),
            durationSeconds: 1_200,
            distanceMeters: 1_500
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [workout(start: start, duration: 1_200, sessions: [swim])],
            exercises: [],
            containing: now,
            calendar: calendar
        )
        let distance = try #require(summary.metrics.first { $0.kind == .cardioDistance })

        #expect(distance.formatted(weightUnit: .lb, distanceUnit: .mi) == "1500 m")
    }

    @Test func conditioningAggregatesOnlyCompletedScoreOutputs() {
        let start = date(2026, 8, 12, hour: 8)
        let rounds = ConditioningSectionResult(
            id: UUID(),
            format: .amrap,
            scoreKind: .roundsAndReps,
            elapsedSeconds: 720,
            fullRounds: 4,
            totalReps: 96,
            completed: true
        )
        let intervals = ConditioningSectionResult(
            id: UUID(),
            format: .intervals,
            scoreKind: .completedIntervals,
            elapsedSeconds: 480,
            fullRounds: 8,
            completedIntervals: 8,
            completed: true
        )
        let incomplete = ConditioningSectionResult(
            id: UUID(),
            format: .amrap,
            scoreKind: .roundsAndReps,
            fullRounds: 20,
            totalReps: 500,
            completed: false
        )
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            resultJSON: ConditioningResult(sectionResults: [rounds, intervals, incomplete]).encodedJSON()
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [workout(start: start, duration: 1_500, blocks: [block])],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time, .conditioningRounds, .conditioningReps, .conditioningIntervals])
        #expect(summary.metrics.first { $0.kind == .conditioningRounds }?.value == .count(4))
        #expect(summary.metrics.first { $0.kind == .conditioningReps }?.value == .count(96))
        #expect(summary.metrics.first { $0.kind == .conditioningIntervals }?.value == .count(8))
    }

    @Test func incompleteConditioningResultDoesNotCreateAHeadline() {
        let result = ConditioningSectionResult(
            id: UUID(),
            format: .forTime,
            scoreKind: .elapsedTime,
            elapsedSeconds: 600,
            fullRounds: 2,
            completed: false
        )
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            resultJSON: ConditioningResult(sectionResults: [result]).encodedJSON()
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [workout(start: date(2026, 8, 9), duration: 900, blocks: [block])],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time])
    }

    @Test func yogaUsesLogicalPosesRegionsAndCoveredHeartRate() {
        let start = date(2026, 8, 9, hour: 17)
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            durationSeconds: 1_800,
            avgHR: 104,
            flexibilityExposureJSON: "{\"hips\":600,\"hamstrings\":300}",
            posesCompleted: 12
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [workout(
                start: start,
                duration: 1_800,
                sessions: [session],
                averageHeartRate: 104
            )],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time, .yogaPoses, .yogaRegions, .averageHeartRate])
        #expect(summary.metrics.first { $0.kind == .yogaPoses }?.value == .count(12))
        #expect(summary.metrics.first { $0.kind == .yogaRegions }?.value == .count(2))
    }

    @Test func fingerprintTracksYogaSplitsUsedForLogicalPoseCounts() {
        let start = date(2026, 8, 9, hour: 17)
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            durationSeconds: 600,
            posesCompleted: 12
        )
        let completedWorkout = workout(start: start, duration: 600, sessions: [session])
        let before = HomeWeekMetrics.fingerprint(
            workouts: [completedWorkout],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        session.splits = [
            CardioSplitModel(
                userID: userID,
                cardioSessionID: session.id,
                index: 0,
                distanceMeters: 0,
                durationSeconds: 300,
                paceSecondsPerKm: 0,
                label: "Pigeon — Left",
                startedAt: start,
                endedAt: start.addingTimeInterval(300)
            ),
            CardioSplitModel(
                userID: userID,
                cardioSessionID: session.id,
                index: 1,
                distanceMeters: 0,
                durationSeconds: 300,
                paceSecondsPerKm: 0,
                label: "Pigeon — Right",
                startedAt: start.addingTimeInterval(300),
                endedAt: start.addingTimeInterval(600)
            ),
        ]
        let after = HomeWeekMetrics.fingerprint(
            workouts: [completedWorkout],
            exercises: [],
            containing: now,
            calendar: calendar
        )
        let refreshed = HomeWeekMetrics.summary(
            workouts: [completedWorkout],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(before != after)
        #expect(refreshed.metrics.first { $0.kind == .yogaPoses }?.value == .count(1))
    }

    @Test func mixedWeekRepresentsEachModalityBeforeAddingDepth() {
        let lift = exercise("Deadlift", modality: .strength)
        let set = SetModel(
            userID: userID,
            reps: 5,
            weight: 120,
            completedAt: date(2026, 8, 9, hour: 10)
        )
        let strengthRow = WorkoutExerciseModel(userID: userID, exerciseID: lift.id, sets: [set])

        let runStart = date(2026, 8, 10, hour: 7)
        let run = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: runStart,
            endedAt: runStart.addingTimeInterval(1_800),
            durationSeconds: 1_800,
            distanceMeters: 4_000
        )
        let yogaStart = date(2026, 8, 11, hour: 18)
        let yoga = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: yogaStart,
            endedAt: yogaStart.addingTimeInterval(1_200),
            durationSeconds: 1_200,
            posesCompleted: 8
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [
                workout(start: date(2026, 8, 9, hour: 9), duration: 3_600, exercises: [strengthRow]),
                workout(start: runStart, duration: 1_800, sessions: [run]),
                workout(start: yogaStart, duration: 1_200, sessions: [yoga]),
            ],
            exercises: [lift],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time, .strengthVolume, .cardioDistance, .yogaPoses])
    }

    @Test func fourModalityOverflowUsesLoggedDurationThenRecency() {
        let lift = exercise("Bench Press", modality: .strength)
        let set = SetModel(
            userID: userID,
            reps: 8,
            weight: 80,
            completedAt: date(2026, 8, 9, hour: 10)
        )
        let row = WorkoutExerciseModel(userID: userID, exerciseID: lift.id, sets: [set])
        let runStart = date(2026, 8, 10, hour: 7)
        let run = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: runStart,
            endedAt: runStart.addingTimeInterval(2_400),
            durationSeconds: 2_400,
            distanceMeters: 6_000
        )
        let conditioningResult = ConditioningSectionResult(
            id: UUID(),
            format: .amrap,
            scoreKind: .roundsAndReps,
            elapsedSeconds: 1_800,
            fullRounds: 6,
            totalReps: 120,
            completed: true
        )
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            resultJSON: ConditioningResult(sectionResults: [conditioningResult]).encodedJSON()
        )
        let yogaStart = date(2026, 8, 12, hour: 17)
        let yoga = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: yogaStart,
            endedAt: yogaStart.addingTimeInterval(1_200),
            durationSeconds: 1_200,
            posesCompleted: 10
        )
        let summary = HomeWeekMetrics.summary(
            workouts: [
                workout(start: date(2026, 8, 9, hour: 9), duration: 3_600, exercises: [row]),
                workout(start: runStart, duration: 2_400, sessions: [run]),
                workout(start: date(2026, 8, 11, hour: 8), duration: 1_800, blocks: [block]),
                workout(start: yogaStart, duration: 1_200, sessions: [yoga]),
            ],
            exercises: [lift],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(summary) == [.time, .strengthVolume, .cardioDistance, .conditioningRounds])
    }

    @Test func averageHeartRateRequiresAtLeastHalfOfWeeklyTime() {
        func cardioWorkout(start: Date, duration: Int, averageHeartRate: Int?) -> WorkoutModel {
            let session = CardioSessionModel(
                userID: userID,
                modality: CardioKind.other.rawValue,
                startedAt: start,
                endedAt: start.addingTimeInterval(TimeInterval(duration)),
                durationSeconds: duration,
                avgHR: averageHeartRate
            )
            return workout(
                start: start,
                duration: duration,
                sessions: [session],
                averageHeartRate: averageHeartRate
            )
        }

        let covered = HomeWeekMetrics.summary(
            workouts: [
                cardioWorkout(start: date(2026, 8, 9, hour: 8), duration: 3_600, averageHeartRate: 140),
                cardioWorkout(start: date(2026, 8, 10, hour: 8), duration: 3_600, averageHeartRate: nil),
            ],
            exercises: [],
            containing: now,
            calendar: calendar
        )
        let sparse = HomeWeekMetrics.summary(
            workouts: [
                cardioWorkout(start: date(2026, 8, 9, hour: 8), duration: 1_800, averageHeartRate: 140),
                cardioWorkout(start: date(2026, 8, 10, hour: 8), duration: 5_400, averageHeartRate: nil),
            ],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(covered) == [.time, .averageHeartRate])
        #expect(kinds(sparse) == [.time])
    }

    @Test func emptyOrUnclassifiedWeekNeverInventsZeroMetrics() {
        let empty = HomeWeekMetrics.summary(
            workouts: [],
            exercises: [],
            containing: now,
            calendar: calendar
        )
        let durationOnly = HomeWeekMetrics.summary(
            workouts: [workout(start: date(2026, 8, 10), duration: 3_600)],
            exercises: [],
            containing: now,
            calendar: calendar
        )

        #expect(kinds(empty) == [.time])
        #expect(empty.metrics.first?.value == .duration(0))
        #expect(kinds(durationOnly) == [.time])
    }
}
