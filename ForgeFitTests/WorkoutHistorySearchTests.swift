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

    // MARK: Relative-window memo policy (FF-017)

    @Test func relativeMemoKeysShiftAtMidnightButNotWithinADay() {
        let laterToday = calendar.date(byAdding: .hour, value: 11, to: now)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let filters: [WorkoutHistoryQuery.DateFilter] = [
            .last7Days, .last30Days, .last90Days, .thisYear,
        ]
        for filter in filters {
            var query = WorkoutHistoryQuery()
            query.date = filter
            let atNow = WorkoutHistoryQueryEngine.memoKey(
                fingerprint: "fp", query: query, now: now, calendar: calendar
            )
            // Stable within the calendar day — unrelated interactions must not churn.
            #expect(
                WorkoutHistoryQueryEngine.memoKey(
                    fingerprint: "fp", query: query, now: laterToday, calendar: calendar
                ) == atNow
            )
            // Moves at the local day boundary — the memo must turn over without any
            // query or data change.
            #expect(
                WorkoutHistoryQueryEngine.memoKey(
                    fingerprint: "fp", query: query, now: nextDay, calendar: calendar
                ) != atNow
            )
        }
    }

    @Test func staticMemoKeysAreClockIndependent() {
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!

        var monthQuery = WorkoutHistoryQuery()
        monthQuery.date = .month(
            title: "January 2027",
            interval: DateInterval(
                start: calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!,
                end: calendar.date(from: DateComponents(year: 2027, month: 2, day: 1))!
            )
        )
        var customQuery = WorkoutHistoryQuery()
        customQuery.date = .custom(start: now.addingTimeInterval(-86_400), end: now)

        let queries: [WorkoutHistoryQuery] = [.init(), monthQuery, customQuery]
        for query in queries {
            let before = WorkoutHistoryQueryEngine.memoKey(
                fingerprint: "fp", query: query, now: now, calendar: calendar
            )
            let after = WorkoutHistoryQueryEngine.memoKey(
                fingerprint: "fp", query: query, now: nextDay, calendar: calendar
            )
            #expect(before == after)
        }
    }

    @Test func nextDayBoundaryLandsOnTheFollowingLocalMidnight() {
        let boundary = WorkoutHistoryQueryEngine.nextDayBoundary(after: now, calendar: calendar)
        let expected = calendar.date(from: DateComponents(year: 2027, month: 1, day: 16))!
        #expect(boundary == expected)
    }

    @Test func nextDayBoundarySurvivesDSTFallBack() {
        let newYork = TimeZone(identifier: "America/New_York")!
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = newYork

        // Start before the repeated hour on the fall-back day and ask for the
        // following midnight. The interval is 24.5 hours in absolute time;
        // a fixed 24-hour step would land at 23:30 instead of midnight.
        let beforeFallback = nyCalendar.date(
            from: DateComponents(timeZone: newYork, year: 2027, month: 11, day: 7, hour: 0, minute: 30)
        )!
        let expectedMidnight = nyCalendar.date(
            from: DateComponents(timeZone: newYork, year: 2027, month: 11, day: 8)
        )!
        #expect(
            WorkoutHistoryQueryEngine.nextDayBoundary(after: beforeFallback, calendar: nyCalendar)
            == expectedMidnight
        )
    }

    @Test func relativeFilterRecomputesAcrossMidnightWithoutQueryOrFingerprintChange() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let boundary = calendar.date(byAdding: .day, value: -7, to: now)!

        let morning = strength(daysAgo: 0, title: "Morning", exercise: bench, weight: 100)
        morning.startedAt = now.addingTimeInterval(-60)         // 07:59 — inside the old day's window
        let fresh = strength(daysAgo: 0, title: "Fresh", exercise: bench, weight: 100)
        fresh.startedAt = nextDay.addingTimeInterval(-60)       // only visible after the boundary
        let onBoundary = strength(daysAgo: 7, title: "Boundary", exercise: bench, weight: 100)  // exactly 7*24h back
        let inside = strength(daysAgo: 7, title: "Inside", exercise: bench, weight: 100)
        inside.startedAt = boundary.addingTimeInterval(1)
        let outside = strength(daysAgo: 7, title: "Outside", exercise: bench, weight: 100)
        outside.startedAt = boundary.addingTimeInterval(-1)

        let index = await WorkoutHistoryIndexer.build(
            workouts: [morning, fresh, onBoundary, inside, outside],
            exercises: [bench],
            calendar: calendar
        )

        var query = WorkoutHistoryQuery()
        query.date = .last7Days
        let fingerprint = "fp"   // deliberately frozen — the memo must not need it

        // Mirrors WorkoutHistoryView.filtered: one injected now/calendar drives
        // both the memo key and the engine.
        let memo = Memo<String, [WorkoutHistoryEntry]>()
        var computeCount = 0
        func value(at date: Date) -> [WorkoutHistoryEntry] {
            memo(WorkoutHistoryQueryEngine.memoKey(
                fingerprint: fingerprint, query: query, now: date, calendar: calendar
            )) {
                computeCount += 1
                return WorkoutHistoryQueryEngine.apply(query, to: index, now: date, calendar: calendar)
            }
        }

        let beforeMidnight = value(at: now)
        let afterMidnight = value(at: nextDay)

        #expect(beforeMidnight.map(\.title) == ["Morning", "Inside", "Boundary"])
        #expect(afterMidnight.map(\.title) == ["Fresh", "Morning"])
        #expect(computeCount == 2)   // crossed the day boundary with zero query/fingerprint change
        _ = container
    }

    @Test func staticFilterMemoHoldsAcrossBodyReevaluationsAndMidnight() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let today = strength(daysAgo: 0, title: "Today", exercise: bench, weight: 100)
        today.startedAt = now.addingTimeInterval(-60)
        let index = await WorkoutHistoryIndexer.build(
            workouts: [today], exercises: [bench], calendar: calendar
        )

        var query = WorkoutHistoryQuery()
        query.date = .custom(start: now.addingTimeInterval(-86_400), end: now)

        let memo = Memo<String, [WorkoutHistoryEntry]>()
        var computeCount = 0
        func value(at date: Date) -> [WorkoutHistoryEntry] {
            memo(WorkoutHistoryQueryEngine.memoKey(
                fingerprint: "fp", query: query, now: date, calendar: calendar
            )) {
                computeCount += 1
                return WorkoutHistoryQueryEngine.apply(query, to: index, now: date, calendar: calendar)
            }
        }

        let first = value(at: now)
        let laterSameDay = value(at: now.addingTimeInterval(3_600))
        let nextDay = value(at: calendar.date(byAdding: .day, value: 1, to: now)!)

        #expect(computeCount == 1)   // one compute, two hits — no churn at midnight
        #expect(first == laterSameDay)
        #expect(laterSameDay == nextDay)
        _ = container
    }

    @Test func relativeFilterStaysMemoizedWithinACalendarDay() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let index = await WorkoutHistoryIndexer.build(
            workouts: [strength(daysAgo: 1, title: "Recent", exercise: bench, weight: 100)],
            exercises: [bench],
            calendar: calendar
        )

        var query = WorkoutHistoryQuery()
        query.date = .last90Days

        let memo = Memo<String, [WorkoutHistoryEntry]>()
        var computeCount = 0
        func value(at date: Date) -> [WorkoutHistoryEntry] {
            memo(WorkoutHistoryQueryEngine.memoKey(
                fingerprint: "fp", query: query, now: date, calendar: calendar
            )) {
                computeCount += 1
                return WorkoutHistoryQueryEngine.apply(query, to: index, now: date, calendar: calendar)
            }
        }

        let first = value(at: now)
        let laterSameDay = value(at: now.addingTimeInterval(3_600))

        #expect(computeCount == 1)   // unrelated interactions within a day hit the memo
        #expect(first == laterSameDay)
        _ = container
    }

    @Test func last30And90DayWindowsMoveWithTheDay() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        let recent = strength(daysAgo: 1, title: "Recent", exercise: bench, weight: 100)

        for days in [30, 90] {
            let boundary = calendar.date(byAdding: .day, value: -days, to: now)!
            let onBoundary = strength(daysAgo: days, title: "On-\(days)", exercise: bench, weight: 100)
            let inside = strength(daysAgo: days, title: "Inside-\(days)", exercise: bench, weight: 100)
            inside.startedAt = boundary.addingTimeInterval(1)
            let outside = strength(daysAgo: days, title: "Outside-\(days)", exercise: bench, weight: 100)
            outside.startedAt = boundary.addingTimeInterval(-1)

            let index = await WorkoutHistoryIndexer.build(
                workouts: [recent, onBoundary, inside, outside],
                exercises: [bench],
                calendar: calendar
            )

            var query = WorkoutHistoryQuery()
            query.date = days == 30 ? .last30Days : .last90Days

            let today = WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar).map(\.title)
            let tomorrow = WorkoutHistoryQueryEngine.apply(query, to: index, now: nextDay, calendar: calendar).map(\.title)

            // The exact trailing boundary (now − N days) is included before
            // midnight and excluded after; everything inside stays.
            #expect(today == ["Recent", "Inside-\(days)", "On-\(days)"])
            #expect(tomorrow == ["Recent"])
            _ = container
        }
    }

    @Test func thisYearWindowTracksTheYearBoundary() async throws {
        let (container, context) = try TestStore.make()
        let bench = exercise("Bench Press", muscles: ["chest"])
        context.insert(bench)

        let jan1_2027 = calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!
        let jan1_2028 = calendar.date(from: DateComponents(year: 2028, month: 1, day: 1))!

        let prevYear = strength(daysAgo: 360, title: "PrevYear", exercise: bench, weight: 100)
        prevYear.startedAt = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 12))!
        let newYear = strength(daysAgo: 359, title: "NewYear", exercise: bench, weight: 100)
        newYear.startedAt = jan1_2027
        let yearEnd = strength(daysAgo: 2, title: "YearEnd", exercise: bench, weight: 100)
        yearEnd.startedAt = calendar.date(from: DateComponents(year: 2027, month: 12, day: 31, hour: 12))!
        let nextYearJan1 = strength(daysAgo: 1, title: "NextYearJan1", exercise: bench, weight: 100)
        nextYearJan1.startedAt = jan1_2028

        let index = await WorkoutHistoryIndexer.build(
            workouts: [prevYear, newYear, yearEnd, nextYearJan1],
            exercises: [bench],
            calendar: calendar
        )

        var query = WorkoutHistoryQuery()
        query.date = .thisYear

        let in2027 = WorkoutHistoryQueryEngine.apply(query, to: index, now: now, calendar: calendar).map(\.title)
        let in2028 = WorkoutHistoryQueryEngine.apply(query, to: index, now: jan1_2028, calendar: calendar).map(\.title)

        // Half-open year window: Jan 1 00:00:00 belongs to the new year (start
        // inclusive, end exclusive); Dec 31 of the prior year and Jan 1 of the
        // next year fall outside, and the window itself moves with `now`.
        #expect(in2027 == ["YearEnd", "NewYear"])
        #expect(in2028 == ["NextYearJan1"])
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
