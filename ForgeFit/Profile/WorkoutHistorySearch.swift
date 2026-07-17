import Foundation
import ForgeCore
import ForgeData

// MARK: - Index

/// A value-type snapshot of one completed workout, prebuilt so the History
/// screen can search, filter, sort, and scroll without ever faulting a
/// workout's relationship graph. Building the index costs one pass over the
/// sets; every interaction after that is pure array work.
struct WorkoutHistoryEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case strength, cardio, yoga, mixed

        var title: String {
            switch self {
            case .strength: "Strength"
            case .cardio: "Cardio"
            case .yoga: "Yoga"
            case .mixed: "Mixed"
            }
        }

        var systemImage: String {
            switch self {
            case .strength: "dumbbell.fill"
            case .cardio: "figure.run"
            case .yoga: "figure.mind.and.body"
            case .mixed: "figure.cross.training"
            }
        }
    }

    let id: UUID
    let startedAt: Date
    let title: String
    let monthKey: String          // "July 2026" — section header + month search
    let durationSeconds: Int
    let volume: Double            // kg, working sets
    let effectiveSets: Double
    let kind: Kind
    let kindSystemImage: String   // cardio rows show their modality's figure
    let avgHR: Int?
    let isImported: Bool
    let prCount: Int              // exercises that set an all-time e1RM PR here
    let exerciseIDs: Set<UUID>
    let muscles: Set<String>      // folded primary muscles
    let searchText: String        // folded haystack (see indexer)
}

/// Facet vocabularies power the "smart" suggestions: they are built from the
/// user's actual history, so suggestions never offer a filter with zero
/// results.
struct WorkoutHistoryIndex: Sendable {
    struct ExerciseFacet: Identifiable, Sendable, Equatable {
        let id: UUID
        let name: String
        let foldedName: String
        let count: Int
    }

    struct MuscleFacet: Identifiable, Sendable, Equatable {
        var id: String { muscle }
        let muscle: String        // folded, e.g. "chest"
        let count: Int
    }

    struct MonthFacet: Identifiable, Sendable, Equatable {
        var id: String { title }
        let title: String         // "July 2026"
        let foldedTitle: String
        let interval: DateInterval
        let count: Int
    }

    var entries: [WorkoutHistoryEntry] = []   // newest first
    var exercises: [ExerciseFacet] = []       // by frequency desc
    var muscles: [MuscleFacet] = []
    var months: [MonthFacet] = []             // newest first

    static let empty = WorkoutHistoryIndex()
}

/// Builds the history index on the main actor (models are main-bound),
/// yielding periodically so a multi-thousand-workout import never hitches
/// the UI. Result is Sendable; all querying afterwards is pure.
@MainActor
enum WorkoutHistoryIndexer {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func build(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        calendar: Calendar = .current
    ) async -> WorkoutHistoryIndex {
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Oldest → newest so the PR pass sees history in order; reversed at the end.
        let completed = workouts
            .filter { $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { ($0.startedAt, $0.id.uuidString) < ($1.startedAt, $1.id.uuidString) }

        var entries: [WorkoutHistoryEntry] = []
        entries.reserveCapacity(completed.count)
        // CloudKit can't enforce unique constraints, so sync races can leave
        // two rows sharing one workout id — duplicate ForEach IDs corrupt the
        // list layout (same defense as ExercisesListView).
        var seenIDs = Set<UUID>()
        var bestE1RM: [UUID: Double] = [:]
        var exerciseCounts: [UUID: Int] = [:]
        var muscleCounts: [String: Int] = [:]
        var monthCounts: [String: (interval: DateInterval, count: Int)] = [:]

        for (index, workout) in completed.enumerated() {
            if index.isMultiple(of: 200) { await Task.yield() }
            guard seenIDs.insert(workout.id).inserted else { continue }

            let workingSets = workout.exercises.flatMap(\.sets).filter {
                $0.completedAt != nil && $0.setType.countsAsWorkingVolume
            }
            let hasStrength = !workingSets.isEmpty
            let cardioSessions = workout.cardioSessions
            let hasCardio = !cardioSessions.isEmpty
            let isYogaOnly = hasCardio && !hasStrength && cardioSessions.allSatisfy(\.isYogaSession)

            let kind: WorkoutHistoryEntry.Kind = if hasStrength && hasCardio {
                .mixed
            } else if isYogaOnly {
                .yoga
            } else if hasCardio {
                .cardio
            } else {
                .strength
            }

            var haystack: [String] = []
            var entryExerciseIDs: Set<UUID> = []
            var entryMuscles: Set<String> = []
            var prCount = 0

            if let title = workout.title { haystack.append(title) }
            if let notes = workout.notes { haystack.append(notes) }

            var sessionBest: [UUID: Double] = [:]
            for workoutExercise in workout.exercises {
                let sets = workoutExercise.sets.filter {
                    $0.completedAt != nil && $0.setType.countsAsWorkingVolume
                }
                guard !sets.isEmpty else { continue }
                entryExerciseIDs.insert(workoutExercise.exerciseID)
                if let library = exerciseByID[workoutExercise.exerciseID] {
                    haystack.append(library.name)
                    for muscle in library.primaryMuscles {
                        entryMuscles.insert(fold(muscle))
                    }
                }
                let best = sets.compactMap(\.estimated1RM).max() ?? 0
                if best > 0 { sessionBest[workoutExercise.exerciseID] = best }
            }
            for (exerciseID, best) in sessionBest {
                if best > (bestE1RM[exerciseID] ?? 0) {
                    bestE1RM[exerciseID] = best
                    prCount += 1
                }
            }

            var kindImage = WorkoutHistoryEntry.Kind.cardio.systemImage
            for session in cardioSessions {
                haystack.append(session.modality)
                if let cardioKind = CardioKind(rawValue: session.modality) {
                    haystack.append(cardioKind.title)
                    kindImage = cardioKind.systemImage
                }
                if session.isYogaSession {
                    haystack.append("yoga")
                    haystack.append(session.resolvedYogaStyle.rawValue)
                    kindImage = WorkoutHistoryEntry.Kind.yoga.systemImage
                }
            }

            // Date words make "march", "monday", or "jul 14" just work as text.
            let monthKey = workout.startedAt.formatted(.dateTime.month(.wide).year())
            haystack.append(monthKey)
            haystack.append(workout.startedAt.formatted(date: .abbreviated, time: .omitted))
            haystack.append(workout.startedAt.formatted(.dateTime.weekday(.wide)))
            if workout.isImportedHistory {
                haystack.append("imported")
                if let source = workout.externalSource { haystack.append(source) }
            }

            let elapsed = workout.endedAt.map { max(0, Int($0.timeIntervalSince(workout.startedAt))) } ?? 0
            let duration = elapsed > 0
                ? elapsed
                : cardioSessions.compactMap(\.durationSeconds).reduce(0, +)

            let entry = WorkoutHistoryEntry(
                id: workout.id,
                startedAt: workout.startedAt,
                title: workout.title ?? "Workout",
                monthKey: monthKey,
                durationSeconds: duration,
                volume: workingSets.reduce(0) { $0 + ($1.totalVolume ?? 0) },
                effectiveSets: workingSets.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) },
                kind: kind,
                kindSystemImage: (kind == .cardio || kind == .yoga) ? kindImage : kind.systemImage,
                avgHR: cardioSessions.first?.avgHR ?? workout.avgHR,
                isImported: workout.isImportedHistory,
                prCount: prCount,
                exerciseIDs: entryExerciseIDs,
                muscles: entryMuscles,
                searchText: fold(haystack.joined(separator: " "))
            )
            entries.append(entry)

            for id in entryExerciseIDs { exerciseCounts[id, default: 0] += 1 }
            for muscle in entryMuscles { muscleCounts[muscle, default: 0] += 1 }
            if var month = monthCounts[monthKey] {
                month.count += 1
                monthCounts[monthKey] = month
            } else if let interval = calendar.dateInterval(of: .month, for: workout.startedAt) {
                monthCounts[monthKey] = (interval, 1)
            }
        }

        let exerciseFacets = exerciseCounts.compactMap { id, count -> WorkoutHistoryIndex.ExerciseFacet? in
            guard let library = exerciseByID[id] else { return nil }
            return .init(id: id, name: library.name, foldedName: fold(library.name), count: count)
        }
        .sorted { ($0.count, $1.name) > ($1.count, $0.name) }

        let muscleFacets = muscleCounts
            .map { WorkoutHistoryIndex.MuscleFacet(muscle: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.muscle) > ($1.count, $0.muscle) }

        let monthFacets = monthCounts
            .map { WorkoutHistoryIndex.MonthFacet(title: $0.key, foldedTitle: fold($0.key), interval: $0.value.interval, count: $0.value.count) }
            .sorted { $0.interval.start > $1.interval.start }

        return WorkoutHistoryIndex(
            entries: entries.reversed(),
            exercises: exerciseFacets,
            muscles: muscleFacets,
            months: monthFacets
        )
    }
}

// MARK: - Query

struct WorkoutHistoryQuery: Equatable {
    enum KindFilter: String, CaseIterable, Equatable {
        case all, strength, cardio, yoga, mixed

        var title: String {
            switch self {
            case .all: "Type"
            case .strength: "Strength"
            case .cardio: "Cardio"
            case .yoga: "Yoga"
            case .mixed: "Mixed"
            }
        }
    }

    enum DateFilter: Equatable {
        case all
        case last7Days
        case last30Days
        case last90Days
        case thisYear
        case month(title: String, interval: DateInterval)
        case custom(start: Date, end: Date)

        var title: String {
            switch self {
            case .all: "Date"
            case .last7Days: "7 days"
            case .last30Days: "30 days"
            case .last90Days: "90 days"
            case .thisYear: "This year"
            case .month(let title, _): title
            case .custom(let start, let end):
                "\(start.formatted(date: .numeric, time: .omitted))–\(end.formatted(date: .numeric, time: .omitted))"
            }
        }

        /// Closed interval in wall time; custom ranges are whole calendar days
        /// regardless of the picker's time components.
        func interval(now: Date, calendar: Calendar) -> DateInterval? {
            switch self {
            case .all:
                return nil
            case .last7Days:
                return trailing(days: 7, now: now, calendar: calendar)
            case .last30Days:
                return trailing(days: 30, now: now, calendar: calendar)
            case .last90Days:
                return trailing(days: 90, now: now, calendar: calendar)
            case .thisYear:
                return calendar.dateInterval(of: .year, for: now)
            case .month(_, let interval):
                return interval
            case .custom(let start, let end):
                let lo = min(start, end)
                let hi = max(start, end)
                let dayStart = calendar.startOfDay(for: lo)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: hi)) ?? hi
                return DateInterval(start: dayStart, end: dayEnd)
            }
        }

        private func trailing(days: Int, now: Date, calendar: Calendar) -> DateInterval {
            let start = calendar.date(byAdding: .day, value: -days, to: now) ?? now
            return DateInterval(start: start, end: now)
        }
    }

    enum SourceFilter: String, CaseIterable, Equatable {
        case all, logged, imported

        var title: String {
            switch self {
            case .all: "Source"
            case .logged: "Logged"
            case .imported: "Imported"
            }
        }
    }

    enum Sort: String, CaseIterable, Equatable, Identifiable {
        case recent, oldest, longest, highestVolume, mostSets

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recent: "Most recent"
            case .oldest: "Oldest first"
            case .longest: "Longest"
            case .highestVolume: "Highest volume"
            case .mostSets: "Most sets"
            }
        }

        /// Month section headers only make sense while the list is in date
        /// order; metric sorts render flat.
        var isChronological: Bool { self == .recent || self == .oldest }
    }

    var searchText = ""
    var kind: KindFilter = .all
    var date: DateFilter = .all
    var muscle: String? = nil
    var exercise: WorkoutHistoryIndex.ExerciseFacet? = nil
    var source: SourceFilter = .all
    var prsOnly = false
    var sort: Sort = .recent

    var hasActiveFilters: Bool {
        kind != .all || date != .all || muscle != nil || exercise != nil
            || source != .all || prsOnly
    }

    var isDefault: Bool {
        !hasActiveFilters && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Applying a query

enum WorkoutHistoryQueryEngine {
    /// Pure filter + sort over the prebuilt index. Multi-word search is AND
    /// semantics: every term must appear somewhere in the entry's haystack.
    static func apply(
        _ query: WorkoutHistoryQuery,
        to index: WorkoutHistoryIndex,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [WorkoutHistoryEntry] {
        let terms = WorkoutHistoryIndexer.fold(query.searchText)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        let dateInterval = query.date.interval(now: now, calendar: calendar)

        var result = index.entries.filter { entry in
            if query.kind != .all, entry.kind.rawValue != query.kind.rawValue { return false }
            // Half-open on purpose: DateInterval.contains is end-INCLUSIVE, which
            // would file a workout starting exactly at a month boundary into the
            // prior month.
            if let dateInterval,
               !(dateInterval.start <= entry.startedAt && entry.startedAt < dateInterval.end) { return false }
            if let muscle = query.muscle, !entry.muscles.contains(muscle) { return false }
            if let exercise = query.exercise, !entry.exerciseIDs.contains(exercise.id) { return false }
            switch query.source {
            case .all: break
            case .logged: if entry.isImported { return false }
            case .imported: if !entry.isImported { return false }
            }
            if query.prsOnly, entry.prCount == 0 { return false }
            if !terms.allSatisfy({ entry.searchText.contains($0) }) { return false }
            return true
        }

        switch query.sort {
        case .recent:
            break   // index order
        case .oldest:
            result.reverse()
        case .longest:
            result.sort { ($0.durationSeconds, $0.startedAt) > ($1.durationSeconds, $1.startedAt) }
        case .highestVolume:
            result.sort { ($0.volume, $0.startedAt) > ($1.volume, $1.startedAt) }
        case .mostSets:
            result.sort { ($0.effectiveSets, $0.startedAt) > ($1.effectiveSets, $1.startedAt) }
        }
        return result
    }

    // MARK: Smart suggestions

    enum Suggestion: Identifiable, Equatable {
        case exercise(WorkoutHistoryIndex.ExerciseFacet)
        case muscle(WorkoutHistoryIndex.MuscleFacet)
        case month(WorkoutHistoryIndex.MonthFacet)
        case prs

        var id: String {
            switch self {
            case .exercise(let facet): "exercise-\(facet.id)"
            case .muscle(let facet): "muscle-\(facet.muscle)"
            case .month(let facet): "month-\(facet.title)"
            case .prs: "prs"
            }
        }
    }

    /// Typed text mapped onto the facets the user's history actually contains,
    /// so one tap converts fuzzy text into a precise filter. Prefix matches
    /// outrank substring matches; frequency breaks ties.
    static func suggestions(
        for text: String,
        index: WorkoutHistoryIndex,
        query: WorkoutHistoryQuery
    ) -> [Suggestion] {
        let folded = WorkoutHistoryIndexer.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard folded.count >= 2 else { return [] }

        func rank(_ candidate: String) -> Int? {
            if candidate.hasPrefix(folded) { return 0 }
            if candidate.contains(folded) { return 1 }
            return nil
        }

        var out: [Suggestion] = []

        if query.exercise == nil {
            let matches = index.exercises
                .compactMap { facet in rank(facet.foldedName).map { (facet, $0) } }
                .sorted { ($0.1, -$0.0.count) < ($1.1, -$1.0.count) }
                .prefix(3)
            out += matches.map { .exercise($0.0) }
        }
        if query.muscle == nil {
            let matches = index.muscles
                .compactMap { facet in rank(facet.muscle).map { (facet, $0) } }
                .sorted { ($0.1, -$0.0.count) < ($1.1, -$1.0.count) }
                .prefix(2)
            out += matches.map { .muscle($0.0) }
        }
        if query.date == .all, let month = index.months.first(where: { rank($0.foldedTitle) != nil }) {
            out.append(.month(month))
        }
        if !query.prsOnly, "personal records".contains(folded) || folded == "pr" || folded == "prs" {
            out.append(.prs)
        }
        return Array(out.prefix(6))
    }
}
