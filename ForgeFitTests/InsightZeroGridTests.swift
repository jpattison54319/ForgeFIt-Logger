import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// The check-in comparison's eligible-day grid: EVERY day in the range gets
/// an explicit zero when nothing was logged, so "No check-in" days follow
/// the same zero policy as tagged days. A grid limited to check-in days
/// would leave the control group holding only days you trained.
struct InsightZeroGridTests {

    private func session(daysAgo: Int, volume: Double, now: Date) -> InsightSessionSnapshot {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return InsightSessionSnapshot(
            id: UUID(), startedAt: start, durationSeconds: 3_600,
            strengthDurationSeconds: 3_600, volumeKg: volume, workingSets: 10,
            reps: 50, hasStrength: true, isCardio: false, hasYoga: false,
            modality: "strength", routineID: nil, exerciseIDs: [],
            primaryMuscles: [], weekday: 2, isImported: false,
            readinessAtStart: nil
        )
    }

    @Test func everyEligibleDayCarriesAnExplicitZero() async {
        let now = Date()
        let calendar = Calendar.current
        let recipe = InsightRecipe(
            shape: .groupComparison, primaryMetricID: "strength.volume",
            dimension: .checkinTag, range: .fourWeeks, bucket: .daily
        )

        let checkin = InsightCheckinSnapshot(
            date: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: now)!),
            tags: ["stressed"]
        )
        let (table, _) = await InsightDataCoordinator.assembleObservations(
            recipe: recipe,
            sessions: [session(daysAgo: 3, volume: 5_000, now: now)],
            checkinSnapshots: [checkin],
            workouts: [], exercises: []
        )
        let rows = table["strength.volume"] ?? []

        // 28 completed eligible days: one real observation, 27 zeros —
        // including days with neither training nor a check-in. Today is still
        // in progress and must not become a premature zero.
        let days = Set(rows.map { calendar.startOfDay(for: $0.timestamp) })
        #expect(days.count == 28)
        #expect(rows.filter { $0.value == 0 }.count == 27)
        #expect(!days.contains(calendar.startOfDay(for: now)))

        // A day with no check-in and no training still has its zero, and it
        // lands in the "No check-in" group after categorization.
        let quietDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -10, to: now)!)
        let quietRows = rows.filter { calendar.startOfDay(for: $0.timestamp) == quietDay }
        #expect(quietRows.count == 1)
        #expect(quietRows.first?.value == 0)
        #expect(quietRows.first?.category == InsightDataCoordinator.noCheckinCategory)

        // The tagged check-in day (untrained) carries its tag on the zero.
        let taggedRows = rows.filter { calendar.startOfDay(for: $0.timestamp) == checkin.date }
        #expect(taggedRows.map(\.category) == ["stressed"])
        #expect(taggedRows.first?.value == 0)
    }

    @Test func overlappingTagsReceiveTheSameEligibleDayWithoutLosingTheControlGrid() async {
        let now = Date()
        let calendar = Calendar.current
        let checkinDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -1, to: now)!
        )
        let recipe = InsightRecipe(
            shape: .groupComparison, primaryMetricID: "strength.volume",
            dimension: .checkinTag, range: .fourWeeks, bucket: .daily
        )
        let (table, _) = await InsightDataCoordinator.assembleObservations(
            recipe: recipe,
            sessions: [session(daysAgo: 3, volume: 5_000, now: now)],
            checkinSnapshots: [
                InsightCheckinSnapshot(date: checkinDate, tags: ["sore", "stressed"]),
            ],
            workouts: [], exercises: [], now: now, calendar: calendar
        )
        let rows = table["strength.volume"] ?? []
        let taggedRows = rows.filter {
            calendar.startOfDay(for: $0.timestamp) == checkinDate
        }
        #expect(Set(taggedRows.compactMap(\.category)) == ["sore", "stressed"])
        #expect(taggedRows.count == 2)
        #expect(taggedRows.allSatisfy { $0.value == 0 })

        let distinctDays = Set(rows.map { calendar.startOfDay(for: $0.timestamp) })
        #expect(distinctDays.count == 28)
        #expect(rows.contains { $0.category == InsightDataCoordinator.noCheckinCategory })
    }

    /// Group-grid injection is authorized by metric missingness semantics,
    /// not merely by `aggregation == sum`. A missing HealthKit sensor reading
    /// stays absent instead of turning every eligible day into measured zero.
    @Test func optionalSensorSumsAreNeverZeroInjected() async {
        let now = Date()
        let calendar = Calendar.current
        let recipe = InsightRecipe(
            shape: .groupComparison, primaryMetricID: "health.activeEnergy",
            dimension: .checkinTag, range: .fourWeeks, bucket: .daily
        )
        let healthInputs = InsightDataCoordinator.HealthInputs(
            activity: [
                InsightDailyActivitySnapshot(
                    date: calendar.date(byAdding: .day, value: -1, to: now)!,
                    steps: nil, exerciseMinutes: nil, activeEnergyKcal: nil
                ),
            ]
        )
        let (table, _) = await InsightDataCoordinator.assembleObservations(
            recipe: recipe, sessions: [], checkinSnapshots: [],
            healthInputs: healthInputs, workouts: [], exercises: [],
            now: now, calendar: calendar
        )
        #expect(table["health.activeEnergy"]?.isEmpty == true)
    }

    @Test func measurementDomainStartsAtThatMeasurementNotUnrelatedTraining() async {
        let now = Date()
        var oldWorkout = session(daysAgo: 100, volume: 4_000, now: now)
        oldWorkout.avgRPE = nil
        oldWorkout.rpeSampleCount = 0
        var firstRatedWorkout = session(daysAgo: 10, volume: 5_000, now: now)
        firstRatedWorkout.avgRPE = 8
        firstRatedWorkout.rpeSampleCount = 10
        let recipe = InsightRecipe(
            shape: .trend,
            primaryMetricID: "strength.avgRPE",
            range: .sixMonths,
            bucket: .daily
        )

        let (table, dataStart) = await InsightDataCoordinator.assembleObservations(
            recipe: recipe,
            sessions: [oldWorkout, firstRatedWorkout],
            checkinSnapshots: [],
            workouts: [],
            exercises: [],
            now: now
        )

        #expect(table["strength.avgRPE"]?.count == 1)
        #expect(dataStart == firstRatedWorkout.startedAt)
    }

    /// Session-row caching is keyed by workout edits for speed, but muscle
    /// attribution comes from the exercise library. Editing that metadata
    /// must rebuild the unchanged workout's cached snapshot.
    @Test @MainActor
    func exerciseMetadataRevisionInvalidatesCachedSessionRows() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 15, hour: 12
        )))
        let userID = UUID()
        let exercise = ExerciseLibraryModel(
            ownerID: userID,
            name: "Test press",
            primaryMuscles: ["chest"],
            updatedAt: now.addingTimeInterval(-1_000)
        )
        let completedAt = now.addingTimeInterval(-6 * 86_400)
        let set = SetModel(
            userID: userID,
            reps: 10,
            weight: 100,
            completedAt: completedAt
        )
        let workoutExercise = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            sets: [set]
        )
        let workout = WorkoutModel(
            userID: userID,
            startedAt: completedAt.addingTimeInterval(-3_600),
            endedAt: completedAt,
            updatedAt: now.addingTimeInterval(-500),
            exercises: [workoutExercise]
        )
        let recipe = InsightRecipe(
            shape: .trend,
            primaryMetricID: InsightMetricCatalog.muscleSetsID(for: "chest"),
            range: .fourWeeks,
            bucket: .daily
        )
        let coordinator = InsightDataCoordinator()
        defer { coordinator.invalidate() }

        let before = await coordinator.result(
            for: recipe,
            workouts: [workout],
            exercises: [exercise],
            checkins: [],
            now: now,
            calendar: calendar
        )
        #expect(before.series.first?.points.map(\.value).reduce(0, +) == 1)

        // The workout is deliberately untouched. Only the library metadata
        // and its revision move forward.
        exercise.primaryMuscles = ["back"]
        exercise.updatedAt = now

        let after = await coordinator.result(
            for: recipe,
            workouts: [workout],
            exercises: [exercise],
            checkins: [],
            now: now,
            calendar: calendar
        )
        #expect(after.series.first?.points.map(\.value).reduce(0, +) == 0)
    }
}
