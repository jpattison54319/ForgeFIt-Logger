import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutHeartRateResolutionTests {
    private let userID = UUID()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func soleCardioUsesFreshWholeWorkoutHeartRateEverywhere() throws {
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            liveStartedAt: start.addingTimeInterval(30),
            endedAt: start.addingTimeInterval(660),
            durationSeconds: 630,
            distanceMeters: 1_690,
            activeEnergyKcal: 0,
            avgHR: 95,
            maxHR: 100
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(660),
            avgHR: 157,
            maxHR: 173,
            activeEnergyKcal: 139,
            cardioSessions: [session]
        )
        let samples = [
            (date: start, bpm: 150),
            (date: start.addingTimeInterval(330), bpm: 160),
            (date: start.addingTimeInterval(660), bpm: 161),
        ]

        let workoutMetrics = WorkoutHeartRateResolution.workoutMetrics(
            for: workout,
            samples: samples
        )
        let sessionMetrics = WorkoutHeartRateResolution.sessionMetrics(
            for: session,
            in: workout,
            samples: samples
        )

        #expect(workoutMetrics == .init(averageBPM: 157, maximumBPM: 161, activeEnergyKcal: 139))
        #expect(sessionMetrics == workoutMetrics)

        let overview = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: [],
            durationSeconds: 660,
            averageHeartRate: workoutMetrics.averageBPM
        )
        #expect(overview.facts.last == .init(label: "Avg HR", value: "157"))

        let analytics = TrainingAnalytics(workouts: [workout], exercises: [])
        let corrected = try #require(analytics.efficiencyFactor(
            for: session,
            averageHeartRate: sessionMetrics.averageBPM
        ))
        let resolvedByDefault = try #require(analytics.efficiencyFactor(for: session))
        let stale = (1_690 / (630.0 / 60.0)) / 95
        #expect(corrected == resolvedByDefault)
        #expect(corrected < stale)
        #expect(abs(corrected - 1.03) < 0.01)
    }

    @Test func reconcileRepairsStoredValuesForDownstreamAnalytics() {
        let session = timedSession(modality: CardioKind.run.rawValue)
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            avgHR: 157,
            maxHR: 173,
            cardioSessions: [session]
        )
        let samples = [
            (date: start, bpm: 150),
            (date: start.addingTimeInterval(300), bpm: 160),
            (date: start.addingTimeInterval(600), bpm: 161),
        ]

        #expect(WorkoutHeartRateResolution.reconcile(workout: workout, samples: samples))
        #expect(workout.avgHR == 157)
        #expect(workout.maxHR == 161)
        #expect(session.avgHR == 157)
        #expect(session.maxHR == 161)
    }

    @Test func mixedWorkoutKeepsEachTimedBlockWindowSpecific() {
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioKind.run.rawValue,
            startedAt: start.addingTimeInterval(300),
            liveStartedAt: start.addingTimeInterval(300),
            endedAt: start.addingTimeInterval(600),
            durationSeconds: 300,
            avgHR: 95,
            maxHR: 100
        )
        let strength = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            avgHR: 125,
            maxHR: 170,
            exercises: [strength],
            cardioSessions: [session]
        )
        let samples = [
            (date: start.addingTimeInterval(60), bpm: 100),
            (date: start.addingTimeInterval(300), bpm: 150),
            (date: start.addingTimeInterval(450), bpm: 160),
            (date: start.addingTimeInterval(600), bpm: 170),
        ]

        let metrics = WorkoutHeartRateResolution.sessionMetrics(
            for: session,
            in: workout,
            samples: samples
        )

        #expect(!WorkoutHeartRateResolution.isSoleTimedModality(session, in: workout))
        #expect(metrics == .init(averageBPM: 160, maximumBPM: 170))
    }

    @Test func soleYogaAndConditioningShareTheWholeWorkoutContract() {
        for modality in [CardioSessionModel.yogaModality, CardioSessionModel.conditioningModality] {
            let session = timedSession(modality: modality)
            let workout = WorkoutModel(
                userID: userID,
                startedAt: start,
                endedAt: start.addingTimeInterval(600),
                avgHR: 142,
                maxHR: 165,
                cardioSessions: [session]
            )

            #expect(WorkoutHeartRateResolution.isSoleTimedModality(session, in: workout))
            #expect(WorkoutHeartRateResolution.sessionMetrics(
                for: session,
                in: workout,
                samples: []
            ) == .init(averageBPM: 142, maximumBPM: 165))
        }
    }

    private func timedSession(modality: String) -> CardioSessionModel {
        CardioSessionModel(
            userID: userID,
            modality: modality,
            startedAt: start,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(600),
            durationSeconds: 600,
            distanceMeters: 1_600,
            avgHR: 95,
            maxHR: 100
        )
    }
}
