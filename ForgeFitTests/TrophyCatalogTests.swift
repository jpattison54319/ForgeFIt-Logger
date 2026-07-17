import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct TrophyCatalogTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Import provenance

    @Test func liveForgeFitWorkoutsAreNative() {
        #expect(!workout(sourceDevice: "iphone").isImportedHistory)
        #expect(!workout(sourceDevice: "iphone-yoga").isImportedHistory)
        #expect(!workout(sourceDevice: nil).isImportedHistory)
    }

    @Test func everyImportPathIsRecognizedAsImported() {
        #expect(workout(externalSource: "hevy").isImportedHistory)
        #expect(workout(importFingerprint: "abc").isImportedHistory)
        #expect(workout(importBatchID: UUID()).isImportedHistory)
        #expect(workout(sourceDevice: "import-hevy").isImportedHistory)
        #expect(workout(sourceDevice: "healthkit").isImportedHistory)
        #expect(workout(sourceDevice: "healthkit-strava").isImportedHistory)
        #expect(workout(sourceDevice: "gpx-import").isImportedHistory)
    }

    // MARK: - Trophy inputs

    @Test func trophyInputsCountOnlyForgeFitLoggedTraining() {
        let bench = exercise("Bench Press", primary: ["chest"])
        let squat = exercise("Back Squat", primary: ["quadriceps"])
        let workouts = [
            strengthWorkout(daysAgo: 2, exercise: bench, sets: 3),
            strengthWorkout(daysAgo: 4, exercise: bench, sets: 3),
            cardioWorkout(daysAgo: 6, meters: 5_000),
            strengthWorkout(daysAgo: 8, exercise: squat, sets: 5, importBatchID: UUID()),
            cardioWorkout(daysAgo: 10, meters: 10_000, sourceDevice: "healthkit-strava"),
            cardioWorkout(daysAgo: 12, meters: 7_000, sourceDevice: "gpx-import"),
        ]

        let inputs = TrophyCatalog.inputs(workouts: workouts, exercises: [bench, squat])

        #expect(inputs.completedWorkouts == 3)
        #expect(inputs.totalSets == 6)
        #expect(inputs.totalDistanceMeters == 5_000)
        #expect(abs(inputs.lifetimeHours - 2.5) < 0.01)
        // The imported squat sets would be a PR if imports counted.
        #expect(inputs.recordCount == 1)
    }

    @Test func trophyInputsMatchTotalsWhenNothingIsImported() {
        let bench = exercise("Bench Press", primary: ["chest"])
        let workouts = [
            strengthWorkout(daysAgo: 1, exercise: bench, sets: 4),
            cardioWorkout(daysAgo: 3, meters: 3_000),
        ]

        let inputs = TrophyCatalog.inputs(workouts: workouts, exercises: [bench])

        #expect(inputs.completedWorkouts == 2)
        #expect(inputs.totalSets == 4)
        #expect(inputs.totalDistanceMeters == 3_000)
        #expect(inputs.recordCount == 1)
    }

    @Test func catalogContainsNoStreakTrophies() {
        let inputs = TrophyCatalog.Inputs(
            completedWorkouts: 0,
            totalSets: 0,
            totalDistanceMeters: 0,
            lifetimeHours: 0,
            recordCount: 0
        )
        let trophies = TrophyCatalog.trophies(inputs)
        #expect(trophies.count == 13)
        #expect(!trophies.contains { $0.id.contains("streak") || $0.title.lowercased().contains("streak") })
    }

    // MARK: - Fixtures

    private func workout(
        sourceDevice: String? = nil,
        externalSource: String? = nil,
        importFingerprint: String? = nil,
        importBatchID: UUID? = nil
    ) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            sourceDevice: sourceDevice,
            externalSource: externalSource,
            importFingerprint: importFingerprint,
            importBatchID: importBatchID
        )
    }

    private func exercise(_ name: String, primary: [String]) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: UUID(),
            name: name,
            movementPattern: nil,
            primaryMuscles: primary,
            secondaryMuscles: [],
            equipment: "barbell"
        )
    }

    private func strengthWorkout(
        daysAgo: Int,
        exercise: ExerciseLibraryModel,
        sets: Int,
        importBatchID: UUID? = nil
    ) -> WorkoutModel {
        let startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let workoutSets = (0..<sets).map { position in
            SetModel(
                userID: userID,
                position: position,
                setType: .working,
                reps: 8,
                weight: 100,
                completedAt: startedAt.addingTimeInterval(Double(position) * 180)
            )
        }
        let we = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: workoutSets)
        return WorkoutModel(
            userID: userID,
            title: exercise.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_600),
            importBatchID: importBatchID,
            exercises: [we]
        )
    }

    private func cardioWorkout(daysAgo: Int, meters: Double, sourceDevice: String? = nil) -> WorkoutModel {
        let startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let session = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_800),
            durationSeconds: 1_800,
            distanceMeters: meters
        )
        return WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_800),
            sourceDevice: sourceDevice,
            cardioSessions: [session]
        )
    }
}
