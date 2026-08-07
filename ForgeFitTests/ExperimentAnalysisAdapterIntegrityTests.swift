import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct ExperimentAnalysisAdapterIntegrityTests {
    private let userID = ForgeFitDemo.userID
    private let start = Date(timeIntervalSinceReferenceDate: 810_000_000)
    private let day: TimeInterval = 86_400

    @Test
    func globalStrengthVolumeKeepsUnknownWorkingSetLoadVisible() throws {
        let exerciseID = UUID()
        let experiment = completedExperiment()
        let reference = strengthWorkout(
            at: start - day,
            exerciseID: exerciseID,
            sets: [workingSet(weight: 80, reps: 5)]
        )
        let current = strengthWorkout(
            at: start + day,
            exerciseID: exerciseID,
            sets: [
                workingSet(weight: 100, reps: 5),
                workingSet(weight: nil, reps: 5),
            ]
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [reference, current],
            exercises: []
        )
        let volume = try #require(result.metrics.first {
            $0.selection.metricID == "strength.volume"
                && $0.selection.scope == nil
        })

        #expect(volume.current.value == 500)
        #expect(volume.current.coverage.observationCount == 2)
        #expect(volume.current.coverage.validValueCount == 1)
        #expect(volume.current.coverage.missingValueCount == 1)
        #expect(volume.reference.value == 400)
    }

    @Test
    func globalStrengthVolumeIsUnknownWhenEveryAttemptedLoadIsUnknown() throws {
        let experiment = completedExperiment()
        let current = strengthWorkout(
            at: start + day,
            exerciseID: UUID(),
            sets: [workingSet(weight: nil, reps: 5)]
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [current],
            exercises: []
        )
        let volume = try #require(result.metrics.first {
            $0.selection.metricID == "strength.volume"
                && $0.selection.scope == nil
        })

        #expect(volume.current.value == nil)
        #expect(volume.current.coverage.observationCount == 1)
        #expect(volume.current.coverage.missingValueCount == 1)
    }

    @Test
    func globalRepsKeepsMissingWorkingSetRepsVisible() throws {
        let experiment = completedExperiment()
        let current = strengthWorkout(
            at: start + day,
            exerciseID: UUID(),
            sets: [
                workingSet(weight: 100, reps: 5),
                workingSet(weight: 100, reps: nil),
            ]
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [current],
            exercises: []
        )
        let reps = try #require(result.metrics.first {
            $0.selection.metricID == "strength.reps"
        })

        #expect(reps.current.value == 5)
        #expect(reps.current.coverage.observationCount == 2)
        #expect(reps.current.coverage.validValueCount == 1)
        #expect(reps.current.coverage.missingValueCount == 1)
    }

    @Test
    func incompleteBodyweightLoadCannotProduceAnEstimatedOneRepMax() throws {
        let experiment = completedExperiment()
        let exerciseID = UUID()
        let incomplete = SetModel(
            userID: userID,
            setType: .working,
            weightMode: .bodyweightAdded,
            reps: 5,
            addedWeight: 20,
            bodyweightKg: nil,
            completedAt: start
        )
        let current = strengthWorkout(
            at: start + day,
            exerciseID: exerciseID,
            sets: [incomplete]
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [current],
            exercises: []
        )
        let estimated = try #require(result.metrics.first {
            $0.selection.metricID == ExperimentDetailedMetric.exerciseBestEstimated1RM.rawValue
                && $0.selection.scope?.id == exerciseID.uuidString
        })

        #expect(estimated.current.value == nil)
        #expect(estimated.current.coverage.observationCount == 1)
        #expect(estimated.current.coverage.missingValueCount == 1)
    }

    @Test
    func invalidStoredCustomValuesRemainVisibleAsMissingCoverage() throws {
        let experiment = completedExperiment()
        let numberTracker = tracker(
            experimentID: experiment.id,
            label: "Dose",
            unit: "mg"
        )
        let ratingTracker = ExperimentTrackerModel(
            userID: userID,
            experimentID: experiment.id,
            label: "Energy",
            type: .rating,
            cadence: .daily,
            createdAt: start
        )
        let mismatched = ExperimentEntryModel(
            userID: userID,
            experimentID: experiment.id,
            trackerID: numberTracker.id,
            observedAt: start + day,
            value: .note("legacy value")
        )
        let outOfRange = ExperimentEntryModel(
            userID: userID,
            experimentID: experiment.id,
            trackerID: ratingTracker.id,
            observedAt: start + day,
            value: .rating(8)
        )

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [numberTracker, ratingTracker],
            entries: [mismatched, outOfRange],
            workouts: [],
            exercises: []
        )
        let number = try #require(customMetric(
            trackerID: numberTracker.id,
            in: result
        ))
        let rating = try #require(customMetric(
            trackerID: ratingTracker.id,
            in: result
        ))

        #expect(number.current.value == nil)
        #expect(number.current.coverage.observationCount == 1)
        #expect(number.current.coverage.missingValueCount == 1)
        #expect(rating.current.value == nil)
        #expect(rating.current.coverage.observationCount == 1)
        #expect(rating.current.coverage.missingValueCount == 1)
    }

    @Test
    func anotherExperimentUsesOnlyExplicitCompatibleTrackerPairs() throws {
        let experiment = completedExperiment()
        let referenceExperimentID = UUID()
        let currentTracker = tracker(
            experimentID: experiment.id,
            label: "Morning glucose",
            unit: "mg/dL"
        )
        let referenceTracker = tracker(
            experimentID: referenceExperimentID,
            label: "Fasting glucose",
            unit: " MG/DL "
        )
        let unpairedTracker = tracker(
            experimentID: referenceExperimentID,
            label: "Morning glucose",
            unit: "mg/dL"
        )
        let currentEntry = entry(
            experimentID: experiment.id,
            trackerID: currentTracker.id,
            at: start + day,
            value: 105
        )
        let referenceEntry = entry(
            experimentID: referenceExperimentID,
            trackerID: referenceTracker.id,
            at: start - day,
            value: 95
        )
        let unpairedEntry = entry(
            experimentID: referenceExperimentID,
            trackerID: unpairedTracker.id,
            at: start - day,
            value: 999
        )
        let reference: ExperimentReferenceSelection = .experiment(
            id: referenceExperimentID,
            start: start - 7 * day,
            end: start,
            timeZoneIdentifier: "UTC"
        )

        let unpairedResult = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [currentTracker, referenceTracker, unpairedTracker],
            entries: [currentEntry, referenceEntry, unpairedEntry],
            workouts: [],
            exercises: [],
            reference: reference,
            now: start + 8 * day
        )
        let unpairedMetric = try #require(customMetric(
            trackerID: currentTracker.id,
            in: unpairedResult
        ))
        #expect(unpairedMetric.current.value == 105)
        #expect(unpairedMetric.reference.value == nil)
        #expect(unpairedResult.metrics.count {
            $0.selection.metricID == "custom.tracker"
        } == 1)

        let pairedResult = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [currentTracker, referenceTracker, unpairedTracker],
            entries: [currentEntry, referenceEntry, unpairedEntry],
            workouts: [],
            exercises: [],
            reference: reference,
            customTrackerPairs: [currentTracker.id: referenceTracker.id],
            now: start + 8 * day
        )
        let pairedMetric = try #require(customMetric(
            trackerID: currentTracker.id,
            in: pairedResult
        ))
        #expect(pairedMetric.current.value == 105)
        #expect(pairedMetric.reference.value == 95)
        #expect(pairedMetric.comparisonAbsoluteChange == 10)
    }

    @Test
    func incompatibleNumberUnitsCannotBePaired() {
        let current = tracker(
            experimentID: UUID(),
            label: "Dose",
            unit: "mg"
        )
        let reference = tracker(
            experimentID: UUID(),
            label: "Dose",
            unit: "g"
        )

        #expect(!ExperimentAnalysisAdapter.customTrackersAreComparable(
            current,
            reference
        ))
    }

    @Test
    func previousPeriodRetainsTheCurrentTrackerIdentity() throws {
        let experiment = completedExperiment()
        let tracker = tracker(
            experimentID: experiment.id,
            label: "Energy",
            unit: nil
        )
        let entries = [
            entry(
                experimentID: experiment.id,
                trackerID: tracker.id,
                at: start - day,
                value: 4
            ),
            entry(
                experimentID: experiment.id,
                trackerID: tracker.id,
                at: start + day,
                value: 7
            ),
        ]

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [tracker],
            entries: entries,
            workouts: [],
            exercises: []
        )
        let metric = try #require(customMetric(
            trackerID: tracker.id,
            in: result
        ))

        #expect(metric.current.value == 7)
        #expect(metric.reference.value == 4)
    }

    @Test
    func futureCustomReferenceWindowIsRejected() {
        let experiment = completedExperiment()
        let now = start + 10 * day

        #expect(throws: ExperimentAnalysisAdapterError.futureReferenceWindow) {
            try ExperimentAnalysisAdapter.comparisonRequest(
                experiment: experiment,
                reference: .custom(
                    start: now,
                    end: now + day,
                    timeZoneIdentifier: "UTC"
                ),
                now: now
            )
        }
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

    private func tracker(
        experimentID: UUID,
        label: String,
        unit: String?
    ) -> ExperimentTrackerModel {
        ExperimentTrackerModel(
            userID: userID,
            experimentID: experimentID,
            label: label,
            type: .number,
            unit: unit,
            cadence: .daily,
            createdAt: start - 7 * day
        )
    }

    private func entry(
        experimentID: UUID,
        trackerID: UUID,
        at date: Date,
        value: Double
    ) -> ExperimentEntryModel {
        ExperimentEntryModel(
            userID: userID,
            experimentID: experimentID,
            trackerID: trackerID,
            observedAt: date,
            value: .number(value)
        )
    }

    private func workingSet(weight: Double?, reps: Int?) -> SetModel {
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

    private func customMetric(
        trackerID: UUID,
        in result: ExperimentResult
    ) -> ExperimentMetricDelta? {
        result.metrics.first {
            $0.selection.metricID == "custom.tracker"
                && $0.selection.scope?.kind == .tracker
                && $0.selection.scope?.id == trackerID.uuidString
        }
    }
}
