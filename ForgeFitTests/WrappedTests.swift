import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// Wrapped report generation: schedule/date logic, payload building across
/// data-shape edge cases, coaching insight rules, and idempotent persistence.
@MainActor
struct WrappedTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private let userID = ForgeFitDemo.userID

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 10) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: - Fixtures

    private func benchPress() -> ExerciseLibraryModel {
        ExerciseLibraryModel(name: "Bench Press", primaryMuscles: ["chest"], secondaryMuscles: ["triceps"], equipment: "barbell")
    }

    private func row() -> ExerciseLibraryModel {
        ExerciseLibraryModel(name: "Barbell Row", primaryMuscles: ["middle back"], secondaryMuscles: ["biceps"], equipment: "barbell")
    }

    private func strengthWorkout(
        on day: Date,
        exercise: ExerciseLibraryModel,
        weightKg: Double = 80,
        reps: Int = 8,
        sets: Int = 3,
        rpe: Double? = 7.5,
        readiness: Int? = 80
    ) -> WorkoutModel {
        let setModels = (0..<sets).map { index -> SetModel in
            let set = SetModel(userID: userID, position: index, reps: reps, weight: weightKg, rpe: rpe, completedAt: day.addingTimeInterval(Double(index + 1) * 180))
            set.recomputeDerivedMetrics()
            return set
        }
        let we = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: setModels)
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength",
            startedAt: day,
            endedAt: day.addingTimeInterval(3600),
            readinessAtStart: readiness,
            exercises: [we]
        )
        workout.recomputeTotalVolume()
        return workout
    }

    private func cardioWorkout(on day: Date, minutes: Int = 30, avgHR: Int? = 140, zoneSeconds: [Int]? = nil) -> WorkoutModel {
        let session = CardioSessionModel(userID: userID, modality: CardioKind.run.rawValue)
        session.startedAt = day
        session.endedAt = day.addingTimeInterval(Double(minutes) * 60)
        session.durationSeconds = minutes * 60
        session.distanceMeters = Double(minutes) * 150
        session.avgHR = avgHR
        if let zoneSeconds { session.hrZoneSeconds = zoneSeconds }
        return WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: day,
            endedAt: day.addingTimeInterval(Double(minutes) * 60),
            avgHR: avgHR,
            maxHR: avgHR.map { $0 + 20 },
            cardioSessions: [session]
        )
    }

    /// A solid mixed June 2026: 10 strength (2 exercises), 4 runs, spread
    /// across the month.
    private func juneFixture() -> (workouts: [WorkoutModel], exercises: [ExerciseLibraryModel]) {
        let bench = benchPress()
        let rowEx = row()
        var workouts: [WorkoutModel] = []
        for (index, day) in [2, 4, 6, 9, 11, 13, 16, 18, 23, 27].enumerated() {
            let exercise = index % 2 == 0 ? bench : rowEx
            workouts.append(strengthWorkout(on: date(2026, 6, day), exercise: exercise, weightKg: 80 + Double(index)))
        }
        for day in [3, 10, 17, 24] {
            workouts.append(cardioWorkout(on: date(2026, 6, day), zoneSeconds: [300, 900, 400, 100, 100]))
        }
        return (workouts, [bench, rowEx])
    }

    private func pages(_ payload: WrappedPayload) -> [String] {
        payload.pages.map(\.kind)
    }

    // MARK: - Schedule

    @Test func scheduleDueMonthIsAlwaysThePreviousMonth() {
        typealias Schedule = WrappedReportService.WrappedSchedule
        let onFirst = Schedule.dueMonthStart(now: date(2026, 7, 1), calendar: cal)
        #expect(onFirst == date(2026, 6, 1, hour: 0))
        // Opening the app days later still points at the same month — no skips.
        let midMonth = Schedule.dueMonthStart(now: date(2026, 7, 19), calendar: cal)
        #expect(midMonth == date(2026, 6, 1, hour: 0))
        // Year boundary: Jan 1 wants December of the prior year.
        let january = Schedule.dueMonthStart(now: date(2027, 1, 1), calendar: cal)
        #expect(january == date(2026, 12, 1, hour: 0))
    }

    @Test func scheduleYearlyIsDueOnlyInJanuary() {
        typealias Schedule = WrappedReportService.WrappedSchedule
        #expect(Schedule.dueYear(now: date(2027, 1, 1), calendar: cal) == 2026)
        #expect(Schedule.dueYear(now: date(2027, 1, 31), calendar: cal) == 2026)
        #expect(Schedule.dueYear(now: date(2027, 2, 1), calendar: cal) == nil)
        #expect(Schedule.dueYear(now: date(2026, 7, 15), calendar: cal) == nil)
    }

    @Test func scheduleRefreshWindowCoversEarlyMonthOnly() {
        typealias Schedule = WrappedReportService.WrappedSchedule
        #expect(Schedule.isInRefreshWindow(now: date(2026, 7, 1), calendar: cal))
        #expect(Schedule.isInRefreshWindow(now: date(2026, 7, 4), calendar: cal))
        #expect(!Schedule.isInRefreshWindow(now: date(2026, 7, 5), calendar: cal))
    }

    // MARK: - Builder

    @Test func emptyMonthProducesNoReport() {
        let builder = WrappedBuilder(workouts: [], exercises: [], calendar: cal)
        #expect(builder.buildMonth(starting: date(2026, 6, 1)) == nil)
    }

    @Test func mixedMonthBuildsTheFullStory() throws {
        let (workouts, exercises) = juneFixture()
        let builder = WrappedBuilder(workouts: workouts, exercises: exercises, calendar: cal)
        let payload = try #require(builder.buildMonth(starting: date(2026, 6, 1)))

        #expect(payload.title == "June Wrapped")
        let kinds = pages(payload)
        #expect(kinds.first == "cover")
        #expect(kinds.last == "recap")
        #expect(kinds.contains("bigStats"))
        #expect(kinds.contains("trainingMix"))
        #expect(kinds.contains("calendar"))
        #expect(kinds.contains("signatureExercise"))
        #expect(kinds.contains("muscleMap"))
        #expect(kinds.contains("cardioEngine"))
        #expect(kinds.contains("heartRate"))
        #expect(kinds.contains("bossBattle"))
        #expect(kinds.contains("nextFocus"))
        // No May data → no month-over-month page.
        #expect(!kinds.contains("comparison"))

        // Heatmap carries exactly the trained day numbers.
        for case let .calendar(heatmap) in payload.pages {
            #expect(heatmap.activeDays == [2, 3, 4, 6, 9, 10, 11, 13, 16, 17, 18, 23, 24, 27])
        }
        for case let .bigStats(stats) in payload.pages {
            #expect(stats.workouts == 14)
            #expect(stats.activeDays == 14)
        }
        // Round-trips through JSON unchanged (the persistence format).
        let decoded = WrappedPayload.decode(from: payload.encodedJSON())
        #expect(decoded == payload)
    }

    @Test func cardioOnlyMonthSkipsStrengthPages() throws {
        let workouts = [3, 10, 17, 24, 28].map { cardioWorkout(on: date(2026, 6, $0)) }
        let builder = WrappedBuilder(workouts: workouts, exercises: [], calendar: cal)
        let payload = try #require(builder.buildMonth(starting: date(2026, 6, 1)))
        let kinds = pages(payload)
        #expect(kinds.contains("cardioEngine"))
        #expect(!kinds.contains("signatureExercise"))
        #expect(!kinds.contains("muscleMap"))
        #expect(!kinds.contains("strengthProgress"))
        #expect(!kinds.contains("trainingMix"))   // one-sided mix isn't a mix
    }

    @Test func strengthOnlyMonthSkipsCardioPages() throws {
        let bench = benchPress()
        let workouts = [2, 5, 9, 12, 16, 19].map { strengthWorkout(on: date(2026, 6, $0), exercise: bench, readiness: nil) }
        let builder = WrappedBuilder(workouts: workouts, exercises: [bench], calendar: cal)
        let payload = try #require(builder.buildMonth(starting: date(2026, 6, 1)))
        let kinds = pages(payload)
        #expect(!kinds.contains("cardioEngine"))
        #expect(kinds.contains("signatureExercise"))
    }

    @Test func singleWorkoutMonthStillBuildsWithoutRankingPages() throws {
        let bench = benchPress()
        let workouts = [strengthWorkout(on: date(2026, 6, 15), exercise: bench)]
        let builder = WrappedBuilder(workouts: workouts, exercises: [bench], calendar: cal)
        let payload = try #require(builder.buildMonth(starting: date(2026, 6, 1)))
        let kinds = pages(payload)
        #expect(kinds.contains("cover"))
        #expect(kinds.contains("bigStats"))
        // Ranking pages need more than one contender.
        #expect(!kinds.contains("bossBattle"))
        #expect(!kinds.contains("strongestWeek"))
    }

    @Test func previousMonthDataEnablesComparisonPage() throws {
        let bench = benchPress()
        var workouts = [2, 9, 16, 23].map { strengthWorkout(on: date(2026, 5, $0), exercise: bench) }
        workouts += [3, 6, 10, 13, 17, 20, 24].map { strengthWorkout(on: date(2026, 6, $0), exercise: bench) }
        let builder = WrappedBuilder(workouts: workouts, exercises: [bench], calendar: cal)
        let payload = try #require(builder.buildMonth(starting: date(2026, 6, 1)))
        #expect(pages(payload).contains("comparison"))
        for case let .comparison(delta) in payload.pages {
            #expect(delta.workoutsDelta == 3)
            #expect(delta.previousLabel == "May")
        }
    }

    @Test func missingWatchMetricsSkipHeartRatePage() throws {
        let bench = benchPress()
        let workouts = [2, 9, 16].map { strengthWorkout(on: date(2026, 6, $0), exercise: bench) }
        let builder = WrappedBuilder(workouts: workouts, exercises: [bench], calendar: cal)
        let payload = try #require(builder.buildMonth(starting: date(2026, 6, 1)))
        #expect(!pages(payload).contains("heartRate"))
    }

    @Test func yearlyBuildsCelebrationPages() throws {
        var workouts: [WorkoutModel] = []
        let bench = benchPress()
        for month in 1...8 {
            for day in [3, 10, 17, 24] {
                workouts.append(strengthWorkout(on: date(2026, month, day), exercise: bench))
            }
        }
        // Extra September sessions should remain ordinary active days, not a
        // streak-specific celebration page.
        for day in 7...11 {
            workouts.append(strengthWorkout(on: date(2026, 9, day), exercise: bench))
        }
        let builder = WrappedBuilder(workouts: workouts, exercises: [bench], calendar: cal)
        let payload = try #require(builder.buildYear(2026))
        let kinds = pages(payload)
        #expect(payload.title == "2026 Wrapped")
        #expect(!kinds.contains("longestStreak"))
        #expect(kinds.contains("topWorkouts"))
        // Yearly is celebration-weighted: no coaching pages.
        #expect(!kinds.contains("nextFocus"))
        #expect(!kinds.contains("heldBack"))
    }

    @Test func emptyYearProducesNoReport() {
        let builder = WrappedBuilder(workouts: [], exercises: [], calendar: cal)
        #expect(builder.buildYear(2026) == nil)
    }

    // MARK: - Insights

    @Test func hotCardioTriggersZoneTwoPrescription() {
        var ingredients = WrappedInsights.Ingredients()
        ingredients.workouts = 12
        ingredients.activeDays = 12
        ingredients.cardioCount = 5
        ingredients.cardioMinutes = 150
        ingredients.zoneSeconds = [0, 600, 900, 3_000, 2_000]   // 56% Z4+Z5
        let outcome = WrappedInsights.evaluate(ingredients)
        #expect(outcome.heldBack?.headline == "Cardio ran hot")
        #expect(outcome.focus.primary.contains("Zone 2"))
        #expect(outcome.focus.primary.contains("2"))
    }

    @Test func pushPullImbalanceTriggersPullingPrescription() {
        var ingredients = WrappedInsights.Ingredients()
        ingredients.workouts = 10
        ingredients.activeDays = 10
        ingredients.strengthCount = 10
        ingredients.pushSets = 40
        ingredients.pullSets = 12
        let outcome = WrappedInsights.evaluate(ingredients)
        #expect(outcome.heldBack?.headline == "Push outpaced pull")
        #expect(outcome.focus.primary.contains("pulling"))
    }

    @Test func rpeUpWithFlatStrengthPrescribesLighterWeek() {
        var ingredients = WrappedInsights.Ingredients()
        ingredients.workouts = 12
        ingredients.activeDays = 12
        ingredients.strengthCount = 12
        ingredients.avgRPEFirstHalf = 7.2
        ingredients.avgRPESecondHalf = 8.1
        ingredients.bestE1RMGainKg = nil
        let outcome = WrappedInsights.evaluate(ingredients)
        #expect(outcome.heldBack?.headline == "Effort rose, output didn't")
        #expect(outcome.focus.primary.contains("lighter week"))
    }

    @Test func volumeSpikeWithFallingReadinessPrescribesHoldingLoad() {
        var ingredients = WrappedInsights.Ingredients()
        ingredients.workouts = 16
        ingredients.activeDays = 16
        ingredients.volumeKg = 50_000
        ingredients.volumeDeltaKg = 15_000     // +43% vs previous 35k
        ingredients.readinessFirstHalf = 82
        ingredients.readinessSecondHalf = 68
        let outcome = WrappedInsights.evaluate(ingredients)
        #expect(outcome.heldBack?.headline == "Load outran recovery")
        #expect(outcome.focus.primary.contains("Hold total volume"))
    }

    @Test func recordsProduceThePositiveInsightAndMaintain() {
        var ingredients = WrappedInsights.Ingredients()
        ingredients.workouts = 12
        ingredients.activeDays = 12
        ingredients.recordsSet = 4
        let outcome = WrappedInsights.evaluate(ingredients)
        #expect(outcome.improved?.headline == "4 records fell")
        #expect(outcome.focus.maintain?.contains("records") == true)
    }

    @Test func focusPrimaryIsAlwaysSpecific() {
        // Even with nothing wrong, the focus must be a concrete instruction.
        var ingredients = WrappedInsights.Ingredients()
        ingredients.workouts = 14
        ingredients.activeDays = 14
        ingredients.strengthCount = 8
        ingredients.cardioCount = 6
        ingredients.cardioMinutes = 200
        ingredients.zoneSeconds = [1_000, 5_000, 2_000, 800, 200]
        let outcome = WrappedInsights.evaluate(ingredients)
        #expect(outcome.heldBack == nil)
        #expect(!outcome.focus.primary.isEmpty)
        #expect(outcome.focus.primary.contains("week") || outcome.focus.primary.contains("lift"))
    }

    // MARK: - Service (persistence, idempotency, viewed)

    @Test func generationIsIdempotent() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = benchPress()
        context.insert(bench)
        for day in [2, 9, 16, 23] {
            context.insert(strengthWorkout(on: date(2026, 6, day), exercise: bench))
        }
        try context.save()

        let first = WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 1), calendar: cal)
        #expect(first.count == 1)
        #expect(first.first?.year == 2026)
        #expect(first.first?.month == 6)

        // Same day again, and weeks later: no duplicates.
        #expect(WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 1), calendar: cal).isEmpty)
        #expect(WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 20), calendar: cal).isEmpty)

        let all = try context.fetch(FetchDescriptor<WrappedReportModel>())
        #expect(all.count == 1)
    }

    @Test func emptyMonthGeneratesNothing() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let created = WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 1), calendar: cal)
        #expect(created.isEmpty)
        #expect(try context.fetch(FetchDescriptor<WrappedReportModel>()).isEmpty)
    }

    @Test func lateSyncedWorkoutRefreshesReportInsideWindowOnly() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = benchPress()
        context.insert(bench)
        for day in [2, 9, 16] {
            context.insert(strengthWorkout(on: date(2026, 6, day), exercise: bench))
        }
        try context.save()

        let created = WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 1), calendar: cal)
        let report = try #require(created.first)
        let originalPayload = report.payloadJSON

        // A late Health sync adds a June workout on July 2 → refresh in place.
        context.insert(strengthWorkout(on: date(2026, 6, 28), exercise: bench))
        try context.save()
        WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 2), calendar: cal)
        #expect(report.payloadJSON != originalPayload)
        let refreshed = try #require(WrappedPayload.decode(from: report.payloadJSON))
        for case let .bigStats(stats) in refreshed.pages {
            #expect(stats.workouts == 4)
        }

        // Outside the window the payload is frozen.
        let frozen = report.payloadJSON
        context.insert(strengthWorkout(on: date(2026, 6, 30), exercise: bench))
        try context.save()
        WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 10), calendar: cal)
        #expect(report.payloadJSON == frozen)
    }

    @Test func markViewedIsOneWayAndPreservedByRefresh() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = benchPress()
        context.insert(bench)
        context.insert(strengthWorkout(on: date(2026, 6, 9), exercise: bench))
        try context.save()

        let report = try #require(WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 1), calendar: cal).first)
        #expect(!report.isViewed)
        let viewedAt = date(2026, 7, 1, hour: 12)
        WrappedReportService.markViewed(report, in: context, now: viewedAt)
        #expect(report.viewedAt == viewedAt)
        // Second open doesn't move the timestamp.
        WrappedReportService.markViewed(report, in: context, now: date(2026, 7, 3))
        #expect(report.viewedAt == viewedAt)

        // A refresh keeps viewed state.
        context.insert(strengthWorkout(on: date(2026, 6, 20), exercise: bench))
        try context.save()
        WrappedReportService.generateIfDue(in: context, now: date(2026, 7, 2), calendar: cal)
        #expect(report.viewedAt == viewedAt)
    }

    @Test func yearlyGeneratesInJanuaryAlongsideDecemberMonthly() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let bench = benchPress()
        context.insert(bench)
        for month in [3, 6, 9, 12] {
            for day in [4, 11, 18] {
                context.insert(strengthWorkout(on: date(2026, month, day), exercise: bench))
            }
        }
        try context.save()

        let created = WrappedReportService.generateIfDue(in: context, now: date(2027, 1, 1), calendar: cal)
        let types = Set(created.map(\.reportTypeRaw))
        #expect(types == ["monthly", "yearly"])
        let yearly = try #require(created.first { $0.reportTypeRaw == "yearly" })
        #expect(yearly.year == 2026)
        #expect(yearly.month == 0)
        #expect(WrappedReportService.title(for: yearly, calendar: cal) == "2026 Wrapped")

        // Idempotent across the whole of January.
        #expect(WrappedReportService.generateIfDue(in: context, now: date(2027, 1, 15), calendar: cal).isEmpty)
    }
}
