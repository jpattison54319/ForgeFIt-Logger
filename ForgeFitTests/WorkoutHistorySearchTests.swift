import Foundation
import ForgeCore
import ForgeData
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct WorkoutHistorySearchTests {
    private let userID = ForgeFitDemo.userID
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 UTC
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    // MARK: Index

    @Test func indexSkipsInProgressAndDeletedAndOrdersNewestFirst() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let old = strength(daysAgo: 10, title: "Old", exercise: bench, weight: 100)
        let newer = strength(daysAgo: 1, title: "Newer", exercise: bench, weight: 100)
        let inProgress = strength(daysAgo: 0, title: "Live", exercise: bench, weight: 100)
        inProgress.endedAt = nil
        let deleted = strength(daysAgo: 2, title: "Gone", exercise: bench, weight: 100)
        deleted.deletedAt = now

        let index = await WorkoutHistoryIndexer.build(
            workouts: [old, newer, inProgress, deleted],
            exercises: [bench],
            calendar: calendar
        )

        #expect(index.entries.map(\.title) == ["Newer", "Old"])
        _ = container
    }

    @Test func kindsDeriveFromContent() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        let burpee = exercise("Burpee", muscles: ["full body"])
        context.insert(bench)
        context.insert(burpee)

        let lifting = strength(daysAgo: 1, title: "Push", exercise: bench, weight: 100)
        let run = cardio(daysAgo: 2, title: "Tempo", modality: "run")
        let yoga = yogaWorkout(daysAgo: 3, title: "Evening Flow")
        let mixed = strength(daysAgo: 4, title: "Hybrid", exercise: bench, weight: 100)
        mixed.cardioSessions.append(cardioSession(modality: "row"))
        let conditioning = conditioningWorkout(daysAgo: 5, title: "Engine", exercise: burpee)

        let index = await WorkoutHistoryIndexer.build(
            workouts: [lifting, run, yoga, mixed, conditioning],
            exercises: [bench, burpee],
            calendar: calendar
        )
        let kinds = Dictionary(index.entries.map { ($0.title, $0.kind) }, uniquingKeysWith: { a, _ in a })

        #expect(kinds["Push"] == .strength)
        #expect(kinds["Tempo"] == .cardio)
        #expect(kinds["Evening Flow"] == .yoga)
        #expect(kinds["Hybrid"] == .mixed)
        #expect(kinds["Engine"] == .conditioning)
        let conditioningEntry = try #require(index.entries.first { $0.title == "Engine" })
        #expect(conditioningEntry.volume == 0)
        #expect(conditioningEntry.effectiveSets == 0)
        #expect(!conditioningEntry.facts.map(\.label).contains("Sets"))
        _ = container
    }

    @Test func prDetectionMarksFirstAndBeatenBestsOnly() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let first = strength(daysAgo: 30, title: "First", exercise: bench, weight: 100)   // first ever → PR
        let heavier = strength(daysAgo: 20, title: "Heavier", exercise: bench, weight: 110) // beats it → PR
        let lighter = strength(daysAgo: 10, title: "Lighter", exercise: bench, weight: 80)  // no PR

        let index = await WorkoutHistoryIndexer.build(
            workouts: [first, heavier, lighter],
            exercises: [bench],
            calendar: calendar
        )
        let prByTitle = Dictionary(index.entries.map { ($0.title, $0.prCount) }, uniquingKeysWith: { a, _ in a })

        #expect(prByTitle["First"] == 1)
        #expect(prByTitle["Heavier"] == 1)
        #expect(prByTitle["Lighter"] == 0)
        _ = container
    }

    // MARK: Search

    @Test func searchMatchesExerciseNotesMonthAndFoldsDiacritics() async throws {
        let (container, context) = try TestStore.make()
        let squat = exercise("Café Squat", muscles: ["quadriceps"])
        context.insert(squat)

        let workout = strength(daysAgo: 5, title: "Legs", exercise: squat, weight: 140)
        workout.notes = "Belt on top sets"
        let other = cardio(daysAgo: 6, title: "Row Intervals", modality: "row")

        let index = await WorkoutHistoryIndexer.build(
            workouts: [workout, other],
            exercises: [squat],
            calendar: calendar
        )

        func results(_ text: String) -> [String] {
            var query = WorkoutHistoryQuery()
            query.searchText = text
            return WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar).map(\.title)
        }

        #expect(results("cafe squat") == ["Legs"])          // diacritic + case fold
        #expect(results("belt") == ["Legs"])                // notes
        #expect(results("row") == ["Row Intervals"])        // modality
        let monthWord = workout.startedAt.formatted(.dateTime.month(.wide)).lowercased()
        #expect(results(monthWord).contains("Legs"))        // month name
        #expect(results("legs zzz").isEmpty)                // AND semantics
        #expect(results("  ") == ["Legs", "Row Intervals"]) // whitespace = no filter
        _ = container
    }

    @Test func yogaHistorySearchesItsPoseNamesAndMuscles() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let pose = exercise("Low Lunge", muscles: ["hip flexors"])
        context.insert(pose)
        let start = date(daysAgo: 4)
        let plan = YogaFlowPlan(style: .yin, steps: [
            .init(poseID: pose.id, name: pose.name, holdSeconds: 45, side: .bothSides)
        ])
        let block = WorkoutBlockModel(
            userID: userID,
            kind: .yoga,
            planSnapshotJSON: plan.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(90),
            durationSeconds: 90,
            yogaStyleRaw: YogaStyle.yin.rawValue,
            posesCompleted: 2
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Evening Mobility",
            startedAt: start,
            endedAt: start.addingTimeInterval(90),
            cardioSessions: [session],
            blocks: [block]
        )
        context.insert(workout)

        let index = await WorkoutHistoryIndexer.build(
            workouts: [workout],
            exercises: [pose],
            calendar: calendar
        )
        var query = WorkoutHistoryQuery()
        query.searchText = "low lunge"
        let results = WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar)

        #expect(results.map(\.title) == ["Evening Mobility"])
        #expect(results.first?.exerciseIDs.contains(pose.id) == true)
        #expect(results.first?.muscles.contains("hip flexors") == true)
    }

    // MARK: Filters

    @Test func filtersNarrowByKindMuscleExerciseSourceAndPRs() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        let squat = exercise("Back Squat", muscles: ["quadriceps"])
        context.insert(bench)
        context.insert(squat)

        let push = strength(daysAgo: 1, title: "Push", exercise: bench, weight: 100)
        let legs = strength(daysAgo: 2, title: "Legs", exercise: squat, weight: 140)
        let imported = strength(daysAgo: 3, title: "Hevy Push", exercise: bench, weight: 90)
        imported.externalSource = "hevy"
        let run = cardio(daysAgo: 4, title: "Run", modality: "run")
        let conditioning = conditioningWorkout(daysAgo: 5, title: "Conditioning", exercise: squat)

        let index = await WorkoutHistoryIndexer.build(
            workouts: [push, legs, imported, run, conditioning],
            exercises: [bench, squat],
            calendar: calendar
        )

        func titles(_ mutate: (inout WorkoutHistoryQuery) -> Void) -> Set<String> {
            var query = WorkoutHistoryQuery()
            mutate(&query)
            return Set(WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar).map(\.title))
        }

        #expect(titles { $0.kind = .cardio } == ["Run"])
        #expect(titles { $0.kind = .conditioning } == ["Conditioning"])
        #expect(titles { $0.muscle = "chest" } == ["Push", "Hevy Push"])
        #expect(titles { $0.source = .imported } == ["Hevy Push"])
        #expect(titles { $0.source = .logged } == ["Push", "Legs", "Run", "Conditioning"])
        // Imported bench (90 kg) happened FIRST chronologically? No — daysAgo 3
        // is older than daysAgo 1, so it sets the first bench PR; the 100 kg
        // push then beats it. Squat's only session is its own PR.
        #expect(titles { $0.prsOnly = true } == ["Push", "Legs", "Hevy Push"])
        let benchFacet = index.exercises.first { $0.name == "Bench Press" }
        #expect(titles { $0.exercise = benchFacet } == ["Push", "Hevy Push"])
        _ = container
    }

    @Test func customDateRangeIsWholeDaysAndSwapsReversedBounds() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let inside = strength(daysAgo: 5, title: "Inside", exercise: bench, weight: 100)
        let outside = strength(daysAgo: 9, title: "Outside", exercise: bench, weight: 100)
        let index = await WorkoutHistoryIndexer.build(
            workouts: [inside, outside],
            exercises: [bench],
            calendar: calendar
        )

        // Reversed on purpose: end before start. Same calendar day as the
        // workout, mid-day timestamps — whole-day semantics must still include it.
        let day = inside.startedAt
        var query = WorkoutHistoryQuery()
        query.date = .custom(start: day.addingTimeInterval(3_600), end: day.addingTimeInterval(-3_600))

        let titles = WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar).map(\.title)
        #expect(titles == ["Inside"])
        _ = container
    }

    // MARK: Sorting

    @Test func sortsOrderByMetricWithNewestFirstTies() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let short = strength(daysAgo: 1, title: "Short", exercise: bench, weight: 150, durationMinutes: 30)
        let long = strength(daysAgo: 3, title: "Long", exercise: bench, weight: 100, durationMinutes: 90)
        let medium = strength(daysAgo: 2, title: "Medium", exercise: bench, weight: 120, durationMinutes: 60)

        let index = await WorkoutHistoryIndexer.build(
            workouts: [short, long, medium],
            exercises: [bench],
            calendar: calendar
        )

        func titles(_ sort: WorkoutHistoryQuery.Sort) -> [String] {
            var query = WorkoutHistoryQuery()
            query.sort = sort
            return WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar).map(\.title)
        }

        #expect(titles(.recent) == ["Short", "Medium", "Long"])
        #expect(titles(.oldest) == ["Long", "Medium", "Short"])
        #expect(titles(.longest) == ["Long", "Medium", "Short"])
        #expect(titles(.highestVolume) == ["Short", "Medium", "Long"])   // 150 > 120 > 100 kg × same reps
        _ = container
    }

    // MARK: Suggestions

    @Test func suggestionsRankPrefixOverContainsAndRespectActiveFilters() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        let inclineBench = exercise("Incline Bench Press", muscles: ["chest"])
        context.insert(bench)
        context.insert(inclineBench)

        let workouts = [
            strength(daysAgo: 1, title: "A", exercise: bench, weight: 100),
            strength(daysAgo: 2, title: "B", exercise: bench, weight: 100),
            strength(daysAgo: 3, title: "C", exercise: inclineBench, weight: 80),
        ]
        let index = await WorkoutHistoryIndexer.build(workouts: workouts, exercises: [bench, inclineBench], calendar: calendar)

        let fresh = WorkoutHistoryQuery()
        let suggestions = WorkoutHistoryQueryEngine.suggestions(for: "bench", index: index, query: fresh)
        guard case .exercise(let top)? = suggestions.first else {
            Issue.record("expected an exercise suggestion first")
            _ = container
            return
        }
        #expect(top.name == "Bench Press")   // prefix match outranks contains despite both matching

        // One-character queries stay quiet; PR keyword suggests the PR filter.
        #expect(WorkoutHistoryQueryEngine.suggestions(for: "b", index: index, query: fresh).isEmpty)
        #expect(WorkoutHistoryQueryEngine.suggestions(for: "pr", index: index, query: fresh).contains(.prs))

        // An active exercise filter removes exercise suggestions.
        var filtered = fresh
        filtered.exercise = index.exercises.first
        let noExercises = WorkoutHistoryQueryEngine.suggestions(for: "bench", index: index, query: filtered)
        #expect(!noExercises.contains { if case .exercise = $0 { true } else { false } })
        _ = container
    }

    // MARK: Fixtures

    private func exercise(_ name: String, muscles: [String]) -> ExerciseLibraryModel {
        ExerciseLibraryModel(name: name, primaryMuscles: muscles, equipment: "barbell")
    }

    private func strength(
        daysAgo: Int,
        title: String,
        exercise: ExerciseLibraryModel,
        weight: Double,
        durationMinutes: Int = 60
    ) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let set = SetModel(
            userID: userID,
            setType: .working,
            reps: 8,
            weight: weight,
            rpe: 8,
            completedAt: start.addingTimeInterval(600)
        )
        return WorkoutModel(
            userID: userID,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(durationMinutes * 60)),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: [set])]
        )
    }

    /// Yoga is signalled by the modality string itself (`"yoga"`), matching
    /// `CardioSessionModel.isYogaSession`.
    private func cardioSession(modality: String) -> CardioSessionModel {
        CardioSessionModel(
            userID: userID,
            modality: modality,
            durationSeconds: 1_800
        )
    }

    private func cardio(daysAgo: Int, title: String, modality: String) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let session = cardioSession(modality: modality)
        session.startedAt = start
        session.liveStartedAt = start
        session.endedAt = start.addingTimeInterval(1_800)
        return WorkoutModel(
            userID: userID,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            cardioSessions: [session]
        )
    }

    private func yogaWorkout(daysAgo: Int, title: String) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let session = cardioSession(modality: "yoga")
        session.startedAt = start
        session.liveStartedAt = start
        session.endedAt = start.addingTimeInterval(1_800)
        return WorkoutModel(
            userID: userID,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_800),
            cardioSessions: [session]
        )
    }

    private func conditioningWorkout(
        daysAgo: Int,
        title: String,
        exercise: ExerciseLibraryModel
    ) -> WorkoutModel {
        let start = date(daysAgo: daysAgo)
        let section = ConditioningSection(
            name: "Rounds",
            format: .forTime,
            scoreKind: .elapsedTime,
            rounds: 10,
            movements: [ConditioningMovement(exerciseID: exercise.id, targetValue: 10)]
        )
        let result = ConditioningResult(sectionResults: [
            ConditioningSectionResult(
                id: section.id,
                format: .forTime,
                scoreKind: .elapsedTime,
                elapsedSeconds: 600,
                fullRounds: 10,
                totalReps: 100,
                completed: true
            )
        ])
        let row = WorkoutExerciseModel(
            userID: userID,
            exerciseID: exercise.id,
            sets: (0..<10).map {
                SetModel(userID: userID, position: $0, reps: 10, completedAt: start)
            }
        )
        return WorkoutModel(
            userID: userID,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            conditioningResultJSON: result.encodedJSON(),
            exercises: [row]
        )
    }

    private func date(daysAgo: Int) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: now)!
    }
}
