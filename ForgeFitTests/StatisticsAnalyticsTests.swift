import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct StatisticsAnalyticsTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func muscleDistributionCountsPrimaryFullAndSecondaryHalf() {
        let bench = exercise("Bench Press", primary: ["chest"], secondary: ["triceps"])
        let workout = strengthWorkout(daysAgo: 2, exercise: bench, sets: 4)
        let analytics = TrainingAnalytics(workouts: [workout], exercises: [bench], now: now)

        let shares = analytics.muscleDistribution(in: .fourWeeks)

        #expect(shares.first { $0.muscle == "chest" }?.sets == 4)
        #expect(shares.first { $0.muscle == "triceps" }?.sets == 2)
    }

    @Test func trainingSplitBucketsPushPullLegs() {
        let bench = exercise("Bench Press", primary: ["chest"])
        let row = exercise("Barbell Row", primary: ["middle back"])
        let squat = exercise("Back Squat", primary: ["quadriceps"])
        let workouts = [
            strengthWorkout(daysAgo: 2, exercise: bench, sets: 4),
            strengthWorkout(daysAgo: 3, exercise: row, sets: 4),
            strengthWorkout(daysAgo: 4, exercise: squat, sets: 4),
        ]
        let analytics = TrainingAnalytics(workouts: workouts, exercises: [bench, row, squat], now: now)

        let split = analytics.trainingSplit(in: .fourWeeks)

        #expect(split.map(\.name).sorted() == ["Legs", "Pull", "Push"])
        #expect(split.allSatisfy { abs($0.fraction - 1.0 / 3.0) < 0.01 })
    }

    @Test func topExercisesRankByWorkingSets() {
        let bench = exercise("Bench Press", primary: ["chest"])
        let squat = exercise("Back Squat", primary: ["quadriceps"])
        let workouts = [
            strengthWorkout(daysAgo: 2, exercise: bench, sets: 3),
            strengthWorkout(daysAgo: 3, exercise: squat, sets: 5),
        ]
        let analytics = TrainingAnalytics(workouts: workouts, exercises: [bench, squat], now: now)

        let top = analytics.topExercises(in: .fourWeeks)

        #expect(top.first?.name == "Back Squat")
        #expect(top.first?.workingSets == 5)
        #expect(top.count == 2)
    }

    @Test func repRangesBucketByAdaptationZones() {
        let bench = exercise("Bench Press", primary: ["chest"])
        let workout = strengthWorkout(daysAgo: 1, exercise: bench, sets: 3, repsPerSet: [3, 8, 15])
        let analytics = TrainingAnalytics(workouts: [workout], exercises: [bench], now: now)

        let buckets = analytics.repRangeDistribution(in: .fourWeeks)

        #expect(buckets.first { $0.label == "Strength" }?.sets == 1)
        #expect(buckets.first { $0.label == "Hypertrophy" }?.sets == 1)
        #expect(buckets.first { $0.label == "Endurance" }?.sets == 1)
    }

    @Test func cardioBreakdownAndBestsAggregateByModality() {
        let run = cardioWorkout(daysAgo: 2, modality: "run", minutes: 30, meters: 5_000)
        let ride = cardioWorkout(daysAgo: 3, modality: "cycle", minutes: 60, meters: 20_000)
        let analytics = TrainingAnalytics(workouts: [run, ride], exercises: [], now: now)

        let breakdown = analytics.cardioModalityBreakdown(in: .fourWeeks)
        let bests = analytics.cardioBests(in: .fourWeeks)

        #expect(breakdown.count == 2)
        #expect(breakdown.first?.kind == .cycle)   // most minutes first
        #expect(bests.longestSeconds == 3_600)
        #expect(bests.longestDistanceMeters == 20_000)
        // Best pace comes from the run (6:00/km); cycling doesn't use pace.
        #expect(abs((bests.bestPaceMinutesPerKm ?? 0) - 6.0) < 0.01)
    }

    @Test func monthlyReportComparesAgainstPreviousMonth() throws {
        let calendar = Calendar.current
        let thisMonth = calendar.dateInterval(of: .month, for: now)!.start
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!

        let bench = exercise("Bench Press", primary: ["chest"])
        let workouts = [
            strengthWorkout(startedAt: thisMonth.addingTimeInterval(86_400 * 2), exercise: bench, sets: 4),
            strengthWorkout(startedAt: thisMonth.addingTimeInterval(86_400 * 4), exercise: bench, sets: 4),
            strengthWorkout(startedAt: lastMonth.addingTimeInterval(86_400 * 2), exercise: bench, sets: 4),
        ]
        let analytics = TrainingAnalytics(workouts: workouts, exercises: [bench], now: now)

        let months = analytics.monthsWithHistory()
        #expect(months.count == 2)

        let report = analytics.monthlyReport(for: thisMonth)
        #expect(report.workouts == 2)
        #expect(report.workoutsDelta == 1)
        #expect(report.topExercises.first?.name == "Bench Press")
        #expect(report.topMuscles.first?.muscle == "chest")
    }

    // MARK: - Fixtures

    private func exercise(_ name: String, primary: [String], secondary: [String] = []) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: UUID(),
            name: name,
            movementPattern: nil,
            primaryMuscles: primary,
            secondaryMuscles: secondary,
            equipment: "barbell"
        )
    }

    private func strengthWorkout(daysAgo: Int, exercise: ExerciseLibraryModel, sets: Int, repsPerSet: [Int]? = nil) -> WorkoutModel {
        strengthWorkout(
            startedAt: now.addingTimeInterval(-Double(daysAgo) * 86_400),
            exercise: exercise,
            sets: sets,
            repsPerSet: repsPerSet
        )
    }

    private func strengthWorkout(startedAt: Date, exercise: ExerciseLibraryModel, sets: Int, repsPerSet: [Int]? = nil) -> WorkoutModel {
        let workoutSets = (0..<sets).map { position in
            SetModel(
                userID: userID,
                position: position,
                setType: .working,
                reps: repsPerSet.map { $0[position % $0.count] } ?? 8,
                weight: 100,
                completedAt: startedAt.addingTimeInterval(Double(position) * 180)
            )
        }
        let we = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: workoutSets)
        let workout = WorkoutModel(
            userID: userID,
            title: exercise.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_600),
            exercises: [we]
        )
        workout.recomputeTotalVolume()
        return workout
    }

    private func cardioWorkout(daysAgo: Int, modality: String, minutes: Int, meters: Double) -> WorkoutModel {
        let startedAt = now.addingTimeInterval(-Double(daysAgo) * 86_400)
        let session = CardioSessionModel(
            userID: userID,
            modality: modality,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(minutes * 60)),
            durationSeconds: minutes * 60,
            distanceMeters: meters
        )
        return WorkoutModel(
            userID: userID,
            title: modality.capitalized,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(minutes * 60)),
            cardioSessions: [session]
        )
    }
}
