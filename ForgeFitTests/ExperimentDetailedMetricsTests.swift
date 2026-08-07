import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct ExperimentDetailedMetricsTests {
    private let userID = ForgeFitDemo.userID
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400

    @Test func exerciseMetricsUseExactWindowsAndKeepMissingLoadsVisible() throws {
        let exercise = ExerciseLibraryModel(
            id: UUID(),
            name: "Bench Press",
            primaryMuscles: ["chest"],
            equipment: "barbell"
        )
        let experiment = completedExperiment()
        let referenceWorkout = strengthWorkout(
            at: start - day,
            exerciseID: exercise.id,
            sets: [workingSet(weight: 80, reps: 5)]
        )
        let currentWorkout = strengthWorkout(
            at: start + day,
            exerciseID: exercise.id,
            sets: [
                workingSet(weight: 100, reps: 5),
                workingSet(weight: 110, reps: 5),
                workingSet(weight: nil, reps: 5),
            ]
        )
        let endBoundaryWorkout = strengthWorkout(
            at: start + 7 * day,
            exerciseID: exercise.id,
            sets: [workingSet(weight: 200, reps: 5)]
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [referenceWorkout, currentWorkout, endBoundaryWorkout],
            exercises: [exercise]
        )
        let scope = ExperimentMetricScope(
            kind: .exercise,
            id: exercise.id.uuidString
        )

        let volume = try #require(metric(
            .exerciseVolume,
            scope: scope,
            in: result
        ))
        #expect(volume.current.value == 1_050)
        #expect(volume.reference.value == 400)
        #expect(volume.current.coverage.validValueCount == 2)
        #expect(volume.current.coverage.missingValueCount == 1)

        let sets = try #require(metric(
            .exerciseWorkingSets,
            scope: scope,
            in: result
        ))
        #expect(sets.current.value == 3)
        #expect(sets.reference.value == 1)

        let frequency = try #require(metric(
            .exerciseFrequency,
            scope: scope,
            in: result
        ))
        #expect(frequency.current.value == 1)
        #expect(frequency.reference.value == 1)

        let load = try #require(metric(
            .exerciseBestLoad,
            scope: scope,
            in: result
        ))
        #expect(load.current.value == 110)
        #expect(load.reference.value == 80)
        #expect(load.current.coverage.validValueCount == 2)
        #expect(load.current.coverage.missingValueCount == 1)

        let estimated1RM = try #require(metric(
            .exerciseBestEstimated1RM,
            scope: scope,
            in: result
        ))
        #expect((estimated1RM.current.value ?? 0) > (estimated1RM.reference.value ?? 0))
        #expect(estimated1RM.current.provenance == .estimated)
    }

    @Test func cardioMetricsStayModalityScopedAndReportPartialCoverage() throws {
        let experiment = completedExperiment()
        let reference = cardioWorkout(
            at: start - day,
            modality: "run",
            duration: 1_800,
            distance: 4_000,
            averageHeartRate: 155,
            maximumHeartRate: 170,
            zoneSeconds: [120, 600, 780, 240, 60],
            energy: 250,
            power: 200,
            elevation: 40,
            steps: 5_000
        )
        let currentRecorded = cardioWorkout(
            at: start + day,
            modality: "run",
            duration: 1_800,
            distance: 5_000,
            averageHeartRate: 150,
            maximumHeartRate: 175,
            zoneSeconds: [120, 600, 720, 300, 60],
            energy: 300,
            power: 250,
            elevation: 50,
            steps: 6_000
        )
        let currentSparse = cardioWorkout(
            at: start + 2 * day,
            modality: "run",
            duration: 600,
            distance: nil,
            averageHeartRate: 160,
            maximumHeartRate: 180,
            zoneSeconds: [],
            energy: nil,
            power: nil,
            elevation: nil,
            steps: nil
        )
        let endBoundary = cardioWorkout(
            at: start + 7 * day,
            modality: "run",
            duration: 7_200,
            distance: 20_000,
            averageHeartRate: 190,
            maximumHeartRate: 210,
            zoneSeconds: [0, 0, 0, 3_600, 3_600],
            energy: 2_000,
            power: 600,
            elevation: 1_000,
            steps: 30_000
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [reference, currentRecorded, currentSparse, endBoundary],
            exercises: []
        )
        let scope = ExperimentMetricScope(kind: .modality, id: "run")

        #expect(metric(.cardioSessions, scope: scope, in: result)?.current.value == 2)
        #expect(metric(.cardioDuration, scope: scope, in: result)?.current.value == 2_400)
        #expect(metric(.cardioMaximumHeartRate, scope: scope, in: result)?.current.value == 180)
        #expect(metric(.cardioHighZoneTime, scope: scope, in: result)?.current.value == 360)
        #expect(metric(.cardioActiveEnergy, scope: scope, in: result)?.current.value == 300)
        #expect(metric(.cardioPower, scope: scope, in: result)?.current.value == 250)
        #expect(metric(.cardioElevation, scope: scope, in: result)?.current.value == 50)
        #expect(metric(.cardioSteps, scope: scope, in: result)?.current.value == 6_000)

        let distance = try #require(metric(
            .cardioDistance,
            scope: scope,
            in: result
        ))
        #expect(distance.current.value == 5_000)
        #expect(distance.current.coverage.validValueCount == 1)
        #expect(distance.current.coverage.missingValueCount == 1)

        let pace = try #require(metric(
            .cardioPace,
            scope: scope,
            in: result
        ))
        #expect(abs((pace.current.value ?? 0) - 0.36) < 0.000_001)
        #expect(abs((pace.reference.value ?? 0) - 0.45) < 0.000_001)
        #expect((pace.comparisonAbsoluteChange ?? 0) < 0)
        #expect(pace.current.coverage.validValueCount == 1)
        #expect(pace.current.coverage.missingValueCount == 1)

        let averageHeartRate = try #require(metric(
            .cardioAverageHeartRate,
            scope: scope,
            in: result
        ))
        #expect(abs((averageHeartRate.current.value ?? 0) - 152.5) < 0.000_001)
    }

    @Test
    func plannedButUntouchedCardioAndYogaDoNotBecomeAchievements() throws {
        let experiment = completedExperiment()
        let plannedRun = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: start + day,
            endedAt: nil,
            durationSeconds: 3_600,
            distanceMeters: 10_000
        )
        let plannedYoga = CardioSessionModel(
            userID: userID,
            modality: "yoga",
            startedAt: start + day,
            endedAt: nil,
            durationSeconds: 1_800,
            yogaStyleRaw: "vinyasa",
            posesCompleted: 12
        )
        let completedRide = CardioSessionModel(
            userID: userID,
            modality: "cycle",
            startedAt: start + day,
            endedAt: start + day + 1_200,
            durationSeconds: 1_200,
            distanceMeters: 6_000
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start + day,
            endedAt: start + day + 1_200,
            cardioSessions: [plannedRun, plannedYoga, completedRide]
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [workout],
            exercises: []
        )

        #expect(result.metrics.contains {
            $0.selection.scope == ExperimentMetricScope(kind: .modality, id: "run")
        } == false)
        #expect(result.metrics.contains {
            $0.selection.scope == ExperimentMetricScope(kind: .modality, id: "cycle")
        })
        #expect(result.metrics.first {
            $0.selection.metricID == "cardio.duration" && $0.selection.scope == nil
        }?.current.value == 1_200)
        #expect(result.metrics.first {
            $0.selection.metricID == "yoga.duration"
        }?.current.value == 0)
    }

    @Test
    func additiveCardioMetricsAreZeroWhenTheCurrentPeriodHasNoSession() throws {
        let experiment = completedExperiment()
        let reference = cardioWorkout(
            at: start - day,
            modality: "run",
            duration: 1_800,
            distance: 4_000,
            averageHeartRate: 150,
            maximumHeartRate: 170,
            zoneSeconds: [0, 0, 0, 200, 100],
            energy: 250,
            power: 200,
            elevation: 40,
            steps: 5_000
        )
        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [reference],
            exercises: []
        )
        let scope = ExperimentMetricScope(kind: .modality, id: "run")

        for additive in [
            ExperimentDetailedMetric.cardioSessions,
            .cardioDuration,
            .cardioDistance,
            .cardioHighZoneTime,
            .cardioActiveEnergy,
            .cardioElevation,
            .cardioSteps,
        ] {
            #expect(metric(additive, scope: scope, in: result)?.current.value == 0)
        }
        #expect(result.metrics.first {
            $0.selection.metricID == "cardio.distance" && $0.selection.scope == nil
        }?.current.value == 0)
    }

    @Test
    func legacyCardioSpellingsShareOneCanonicalModality() throws {
        let experiment = completedExperiment()
        let reference = cardioWorkout(
            at: start - day,
            modality: "Run",
            duration: 1_000,
            distance: 2_000,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            zoneSeconds: [],
            energy: nil,
            power: nil,
            elevation: nil,
            steps: nil
        )
        let current = cardioWorkout(
            at: start + day,
            modality: "Running",
            duration: 1_200,
            distance: 3_000,
            averageHeartRate: nil,
            maximumHeartRate: nil,
            zoneSeconds: [],
            energy: nil,
            power: nil,
            elevation: nil,
            steps: nil
        )
        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [reference, current],
            exercises: []
        )
        let modalityScopes = Set(result.metrics.compactMap {
            $0.selection.scope?.kind == .modality
                ? $0.selection.scope?.id
                : nil
        })

        #expect(modalityScopes == ["run"])
    }

    @Test
    func trainingDaysUseTheExperimentFrozenTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        let first = try #require(formatter.date(from: "2026-01-02T07:30:00Z"))
        let second = try #require(formatter.date(from: "2026-01-02T08:30:00Z"))
        let workouts = [first, second].map {
            WorkoutModel(
                userID: userID,
                startedAt: $0,
                endedAt: $0.addingTimeInterval(600)
            )
        }

        let rollup = ExperimentTrainingRollup.make(
            workouts: workouts,
            exercises: [],
            start: first.addingTimeInterval(-1),
            end: second.addingTimeInterval(1_000),
            calendar: calendar
        )

        #expect(rollup.trainingDays == 2)
    }

    private func completedExperiment() -> ExperimentModel {
        ExperimentModel(
            userID: userID,
            name: "Test",
            startedAt: start,
            plannedEndAt: start + 7 * day,
            endedAt: start + 7 * day,
            timeZoneIdentifier: "UTC",
            state: .completed
        )
    }

    private func workingSet(weight: Double?, reps: Int) -> SetModel {
        SetModel(
            userID: userID,
            setType: .working,
            reps: reps,
            weight: weight,
            completedAt: start
        )
    }

    private func strengthWorkout(
        at date: Date,
        exerciseID: UUID,
        sets: [SetModel]
    ) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            startedAt: date,
            endedAt: date + 3_600,
            exercises: [
                WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: exerciseID,
                    sets: sets
                ),
            ]
        )
    }

    private func cardioWorkout(
        at date: Date,
        modality: String,
        duration: Int,
        distance: Double?,
        averageHeartRate: Int?,
        maximumHeartRate: Int?,
        zoneSeconds: [Int],
        energy: Double?,
        power: Double?,
        elevation: Double?,
        steps: Int?
    ) -> WorkoutModel {
        let session = CardioSessionModel(
            userID: userID,
            modality: modality,
            startedAt: date,
            endedAt: date + Double(duration),
            durationSeconds: duration,
            distanceMeters: distance,
            activeEnergyKcal: energy,
            avgHR: averageHeartRate,
            maxHR: maximumHeartRate,
            hrZoneSeconds: zoneSeconds,
            totalSteps: steps,
            avgPowerWatts: power,
            elevationGainMeters: elevation
        )
        return WorkoutModel(
            userID: userID,
            startedAt: date,
            endedAt: date + Double(duration),
            cardioSessions: [session]
        )
    }

    private func metric(
        _ metric: ExperimentDetailedMetric,
        scope: ExperimentMetricScope,
        in result: ExperimentResult
    ) -> ExperimentMetricDelta? {
        result.metrics.first {
            $0.selection.metricID == metric.rawValue
                && $0.selection.scope == scope
        }
    }
}
