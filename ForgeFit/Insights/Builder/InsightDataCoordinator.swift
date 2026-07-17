import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Assembles a recipe's inputs and evaluates it. Snapshotting runs on the
/// main actor; Health reads are async through the SAME HealthService
/// derivations every other surface uses; evaluation runs off the main actor
/// with cancellation. Results are memoized on the recipe's analysis
/// signature plus a data fingerprint, so the keep-resident Insights tab
/// never recomputes on unrelated app-state changes.
@MainActor
@Observable
final class InsightDataCoordinator {

    /// Exercise-backed snapshots depend on library metadata (most visibly
    /// primary/secondary muscle assignments), not just on workout rows. Keep
    /// that dependency explicit so a library edit cannot reuse a numerically
    /// stale session snapshot.
    private struct ExerciseLibraryRevision: Hashable {
        let count: Int
        let latestUpdatedAt: Date?
        let latestDeletedAt: Date?

        var fingerprintComponent: String {
            let updated = latestUpdatedAt?.timeIntervalSinceReferenceDate ?? 0
            let deleted = latestDeletedAt?.timeIntervalSinceReferenceDate ?? 0
            return "\(count)|\(updated)|\(deleted)"
        }
    }

    private struct CacheKey: Hashable {
        let signature: String
        let fingerprint: String
        /// Period boundaries use the exact evaluation time, not midnight.
        /// A second-level revision prevents a session crossing the rolling
        /// boundary from being served out of an otherwise same-day cache.
        let windowRevision: Int64
    }

    private var cache: [CacheKey: InsightResult] = [:]
    private var inFlight: [CacheKey: Task<InsightResult, Never>] = [:]
    /// Session snapshots shared across every card evaluating the same data —
    /// N saved cards snapshot the log once, not N times.
    private var snapshotCache: (fingerprint: String, sessions: [InsightSessionSnapshot], checkins: [InsightCheckinSnapshot])?

    static let shared = InsightDataCoordinator()

    /// Changes whenever the training log or Health snapshot changes — cache
    /// entries from older data die with it. Cheap: counts + latest updatedAt.
    /// `metricsRevision` is load-bearing: sleep corrections reprocess the
    /// cached Health series WITHOUT touching `lastRefreshed`, and a corrected
    /// night must never keep serving a stale card. Exercise/routine stamps
    /// matter too — renames change group names and scoped titles.
    func fingerprint(
        workouts: [WorkoutModel],
        checkins: [DailyCheckinModel],
        exercises: [ExerciseLibraryModel] = [],
        routines: [RoutineModel] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let latestWorkout = workouts.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let latestCheckin = checkins.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let exerciseRevision = exerciseLibraryRevision(exercises)
        let latestRoutine = routines.map(\.updatedAt).max()?.timeIntervalSinceReferenceDate ?? 0
        let health = HealthMetricsStore.shared.lastRefreshed?.timeIntervalSinceReferenceDate ?? 0
        let revision = HealthMetricsStore.shared.metricsRevision
        // Range windows and explicit zero grids move even when no model does.
        // A day anchor prevents yesterday's cached result surviving midnight.
        let dayAnchor = calendar.startOfDay(for: now).timeIntervalSinceReferenceDate
        return "\(workouts.count)|\(latestWorkout)|\(checkins.count)|\(latestCheckin)|\(health)|\(revision)|\(exerciseRevision.fingerprintComponent)|\(routines.count)|\(latestRoutine)|\(Fmt.unit.rawValue)|\(dayAnchor)"
    }

    private func exerciseLibraryRevision(
        _ exercises: [ExerciseLibraryModel]
    ) -> ExerciseLibraryRevision {
        ExerciseLibraryRevision(
            count: exercises.count,
            latestUpdatedAt: exercises.map(\.updatedAt).max(),
            latestDeletedAt: exercises.compactMap(\.deletedAt).max()
        )
    }

    func invalidate() {
        cache.removeAll()
        snapshotCache = nil
        sessionRowCache.removeAll()
        healthInputsCache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    /// Health rows shared by range across every card evaluating the same
    /// data — several saved cards must not repeat identical HealthKit
    /// queries or re-run sleep-integrity processing.
    struct HealthInputs {
        var health: [InsightDailyHealthSnapshot] = []
        var activity: [InsightDailyActivitySnapshot] = []
        var bodyweight: [InsightObservation] = []

        nonisolated init(
            health: [InsightDailyHealthSnapshot] = [],
            activity: [InsightDailyActivitySnapshot] = [],
            bodyweight: [InsightObservation] = []
        ) {
            self.health = health
            self.activity = activity
            self.bodyweight = bodyweight
        }
    }

    private var healthInputsCache: [Int: (fingerprint: String, inputs: HealthInputs)] = [:]

    private func healthInputs(recipe: InsightRecipe, fingerprint: String) async -> HealthInputs {
        let needsHealth = recipe.allMetricIDs.contains {
            InsightMetricCatalog.definition(for: $0)?.requiresHealth == true
        }
        guard needsHealth else { return HealthInputs() }
        // Period comparisons analyze twice the selected range (current
        // period + the preceding one).
        var days = (recipe.range.days ?? 365) * (recipe.shape == .periodComparison ? 2 : 1)
        // Relative e1RM explicitly accepts the nearest body-weight reading
        // within seven days, including before the visible window boundary.
        if recipe.allMetricIDs.contains("strength.relativeE1RM") { days += 7 }
        if let cached = healthInputsCache[days], cached.fingerprint == fingerprint {
            return cached.inputs
        }
        var inputs = HealthInputs()
        inputs.bodyweight = await HealthService.shared.bodyMassSeries(days: days)
            .map { InsightObservation(timestamp: $0.date, value: $0.kilograms, provenance: .measured) }
        // The SAME integrity pipeline every other surface trusts: sleep
        // corrections + partial-wear detection, then bestHRV / bestRestingHR
        // fallback semantics — a 5am fragment must not read as a
        // flatteringly high nocturnal HRV here either.
        let daily = SleepOverrideStore.shared.process(await HealthService.shared.dailyMetrics(days: days))
        inputs.health = daily.map { record in
            InsightDailyHealthSnapshot(
                date: record.date,
                hrvSDNN: record.hrvRMSSD ?? record.hrvSDNN,
                nocturnalHRV: record.sleepIsTrustworthy ? record.nocturnalHRV : nil,
                restingHR: record.restingHR,
                sleepingHR: record.sleepIsTrustworthy ? record.sleepingHR : nil,
                respiratoryRate: record.respiratoryRate,
                oxygenSaturationPercent: record.oxygenSaturationPercent,
                sleepTotalMinutes: record.sleepIsTrustworthy ? record.sleepTotalMinutes : nil,
                sleepDeepMinutes: record.sleepIsTrustworthy ? record.sleepDeepMinutes : nil,
                sleepREMMinutes: record.sleepIsTrustworthy ? record.sleepREMMinutes : nil,
                isEstimated: !record.dataQualityFlags.isEmpty
            )
        }
        inputs.activity = (await HealthService.shared.dailyActivityMetrics(days: days)).map {
            InsightDailyActivitySnapshot(
                date: $0.date, steps: $0.steps,
                exerciseMinutes: $0.exerciseMinutes, activeEnergyKcal: $0.activeEnergyKcal
            )
        }
        healthInputsCache[days] = (fingerprint, inputs)
        return inputs
    }

    /// Per-workout rows survive fingerprint changes: editing one workout
    /// re-snapshots that one workout, never the whole history — snapshotting
    /// is main-actor work (SwiftData), and a full-history pass on a large
    /// log is exactly the multi-second tap stall.
    private struct SessionRowCacheEntry {
        let workoutUpdatedAt: Date
        let exerciseRevision: ExerciseLibraryRevision
        let row: InsightSessionSnapshot
    }

    private var sessionRowCache: [UUID: SessionRowCacheEntry] = [:]

    private func snapshots(
        fingerprint: String,
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        checkins: [DailyCheckinModel]
    ) -> (sessions: [InsightSessionSnapshot], checkins: [InsightCheckinSnapshot]) {
        if let cached = snapshotCache, cached.fingerprint == fingerprint {
            return (cached.sessions, cached.checkins)
        }
        let candidates = workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
        let exerciseRevision = exerciseLibraryRevision(exercises)
        let dirty = candidates.filter { workout in
            guard let cached = sessionRowCache[workout.id] else { return true }
            return cached.workoutUpdatedAt != workout.updatedAt
                || cached.exerciseRevision != exerciseRevision
        }
        if !dirty.isEmpty {
            let stamps = Dictionary(dirty.map { ($0.id, $0.updatedAt) }, uniquingKeysWith: { first, _ in first })
            for row in InsightSnapshotter.sessions(workouts: dirty, exercises: exercises) {
                if let stamp = stamps[row.id] {
                    sessionRowCache[row.id] = SessionRowCacheEntry(
                        workoutUpdatedAt: stamp,
                        exerciseRevision: exerciseRevision,
                        row: row
                    )
                }
            }
        }
        let sessions = candidates.compactMap { sessionRowCache[$0.id]?.row }
        if sessionRowCache.count > candidates.count * 2 {
            let live = Set(candidates.map(\.id))
            sessionRowCache = sessionRowCache.filter { live.contains($0.key) }
        }
        let checkinSnapshots = InsightSnapshotter.checkins(checkins)
        snapshotCache = (fingerprint, sessions, checkinSnapshots)
        return (sessions, checkinSnapshots)
    }

    /// Evaluate a recipe. Identical recipe + identical data returns the
    /// cached result synchronously-fast; concurrent requests share one task.
    func result(
        for recipe: InsightRecipe,
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        checkins: [DailyCheckinModel],
        routines: [RoutineModel] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> InsightResult {
        let descriptors = InsightMetricCatalog.descriptors(covering: recipe)
        guard InsightCompatibilityEngine.validate(recipe, descriptors: descriptors).isValid else {
            // Defense in depth for decoded/synced recipes: reject before any
            // Health read, snapshot assembly, or statistics task begins.
            return InsightResult(
                signature: recipe.analysisSignature,
                series: [],
                coverage: InsightCoverage(expectedBuckets: 0, populatedBuckets: 0),
                provenance: .measured,
                warnings: [.invalidRecipe]
            )
        }
        let key = CacheKey(
            signature: recipe.analysisSignature,
            fingerprint: fingerprint(
                workouts: workouts, checkins: checkins, exercises: exercises,
                routines: routines, now: now, calendar: calendar
            ),
            windowRevision: recipe.shape == .periodComparison
                ? Int64(now.timeIntervalSinceReferenceDate)
                : 0
        )
        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return await running.value }

        let snapshot = snapshots(
            fingerprint: key.fingerprint,
            workouts: workouts, exercises: exercises, checkins: checkins
        )
        let routineNames = Dictionary(routines.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let exerciseNames = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        let task = Task<InsightResult, Never> { [weak self] in
            let healthInputs = await self?.healthInputs(recipe: recipe, fingerprint: key.fingerprint) ?? HealthInputs()
            let assembled = await Self.assembleObservations(
                recipe: recipe,
                sessions: snapshot.sessions,
                checkinSnapshots: snapshot.checkins,
                healthInputs: healthInputs,
                workouts: workouts, exercises: exercises,
                routineNames: routineNames, exerciseNames: exerciseNames,
                now: now, calendar: calendar
            )
            let result = await Self.evaluateDetached(
                recipe: recipe, observations: assembled.table, dataStart: assembled.dataStart,
                now: now, calendar: calendar
            )
            // A run cancelled by invalidate() must not resurrect its result
            // into the fresh cache.
            if !Task.isCancelled {
                await MainActor.run { self?.cache[key] = result }
            }
            return result
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        return result
    }

    // MARK: - Input assembly

    /// Builds the per-metric observation table: filtered, categorized
    /// sessions plus ranged Health inputs — and the earliest date the used
    /// domains have ANY data, so windows never demand pre-history.
    static func assembleObservations(
        recipe: InsightRecipe,
        sessions allSessions: [InsightSessionSnapshot],
        checkinSnapshots: [InsightCheckinSnapshot],
        healthInputs: HealthInputs = HealthInputs(),
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        routineNames: [UUID: String] = [:],
        exerciseNames: [UUID: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> (table: [String: [InsightObservation]], dataStart: Date?) {
        let sessions = filteredSessions(
            allSessions, recipe: recipe, checkins: checkinSnapshots,
            routineNames: routineNames, exerciseNames: exerciseNames
        )

        var inputs = InsightMetricCatalog.Inputs(sessions: sessions)
        inputs.scopedExerciseID = scopedExerciseID(recipe)

        var domainStarts: [Date] = []
        let usesTraining = recipe.allMetricIDs.contains { !$0.hasPrefix("health.") || $0 == "health.readiness" }
        if usesTraining, let first = allSessions.map(\.startedAt).min() {
            domainStarts.append(first)
        }
        if recipe.allMetricIDs.contains(where: { $0 == "health.bodyweight" || $0 == "strength.relativeE1RM" }) {
            inputs.bodyweight = healthInputs.bodyweight
            if let first = inputs.bodyweight.map(\.timestamp).min() { domainStarts.append(first) }
        }
        if recipe.allMetricIDs.contains(where: { $0.hasPrefix("health.") && $0 != "health.bodyweight" && $0 != "health.readiness" }) {
            inputs.health = healthInputs.health
            inputs.activity = healthInputs.activity
            let activityIDs: Set<String> = [
                "health.steps", "health.exerciseMinutes", "health.activeEnergy",
            ]
            if recipe.allMetricIDs.contains(where: { $0.hasPrefix("health.") && !activityIDs.contains($0) && $0 != "health.bodyweight" && $0 != "health.readiness" }),
               let first = inputs.health.map(\.date).min() {
                domainStarts.append(first)
            }
            if recipe.allMetricIDs.contains(where: activityIDs.contains),
               let first = inputs.activity.map(\.date).min() {
                domainStarts.append(first)
            }
        }
        // e1RM series per distinct scoped exercise — operand scope first,
        // the shared v1 exercise filter as fallback.
        let globalExerciseID = scopedExerciseID(recipe)
        let e1rmExerciseIDs = Set(recipe.operands.compactMap { operand -> UUID? in
            guard InsightMetricCatalog.definition(for: operand.metricID)?.requiresExerciseScope == true else { return nil }
            return operand.exerciseID ?? globalExerciseID
        })
        for exerciseID in e1rmExerciseIDs {
            inputs.e1rmByExercise[exerciseID] = InsightSnapshotter.e1rmObservations(
                exerciseID: exerciseID, workouts: workouts, exercises: exercises
            )
        }

        var table: [String: [InsightObservation]] = [:]
        for operand in recipe.operands {
            table[operand.key] = InsightMetricCatalog.observations(for: operand, inputs: inputs)
        }
        // Store-level history is only an eligibility boundary for factual
        // event zeros. A measurement's domain begins with THAT measurement,
        // not with the user's first unrelated workout/Health row. Otherwise
        // a newly logged e1RM, sleep metric, or sensor series is shown as
        // artificially sparse before it ever existed.
        for operand in recipe.operands {
            guard InsightMetricCatalog.definition(for: operand.metricID)?.zeroFillPolicy == .never,
                  let first = table[operand.key]?.map(\.timestamp).min() else { continue }
            domainStarts.append(first)
        }
        injectZeroTrainingDays(
            &table, recipe: recipe, checkins: checkinSnapshots, sessions: sessions,
            now: now, calendar: calendar
        )
        categorizeNonSessionRows(
            &table, recipe: recipe, checkins: checkinSnapshots, calendar: calendar
        )
        // A multi-domain comparison starts only once every configured domain
        // exists. Using the earliest start made a newer training log look as
        // though it had factual zeros merely because Health had older rows.
        return (table, domainStarts.max())
    }

    /// "How you feel vs training" must include the days you DIDN'T train.
    /// For tally metrics grouped by check-in state, EVERY completed eligible
    /// day in the
    /// analysis range contributes an explicit zero when nothing was logged —
    /// a grid limited to check-in days would leave the "No check-in" control
    /// group holding only days you trained, biasing it high while tagged
    /// groups carry their rest-day zeros. Days before the engine's window
    /// are trimmed there, so over-injection is harmless.
    private static func injectZeroTrainingDays(
        _ table: inout [String: [InsightObservation]],
        recipe: InsightRecipe,
        checkins: [InsightCheckinSnapshot],
        sessions: [InsightSessionSnapshot],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard recipe.shape == .groupComparison, recipe.dimension == .checkinTag else { return }
        let today = calendar.startOfDay(for: now)
        guard let lastCompletedDay = calendar.date(byAdding: .day, value: -1, to: today) else {
            return
        }
        let lower: Date
        if let days = recipe.range.days {
            // Keep the advertised count while excluding today's incomplete
            // bucket: 4W means the 28 completed days ending yesterday.
            lower = calendar.date(byAdding: .day, value: -days, to: today) ?? today
        } else {
            let firsts = sessions.map(\.startedAt) + checkins.map(\.date)
            lower = calendar.startOfDay(for: firsts.min() ?? today)
        }
        guard lower <= lastCompletedDay else { return }
        var eligibleDays: [Date] = []
        var cursor = lower
        while cursor <= lastCompletedDay {
            eligibleDays.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        for operand in recipe.operands {
            guard InsightMetricCatalog.definition(for: operand.metricID)?.zeroFillPolicy == .zeroWhenAbsent else {
                continue
            }
            var rows = table[operand.key] ?? []
            let coveredDays = Set(rows.map { calendar.startOfDay(for: $0.timestamp) })
            for day in eligibleDays where !coveredDays.contains(day) {
                // Noon keeps the zero inside its calendar day across DST.
                rows.append(InsightObservation(
                    timestamp: day.addingTimeInterval(43_200), value: 0, provenance: .measured
                ))
            }
            table[operand.key] = rows
        }
    }

    /// Health/bodyweight rows carry no category from the snapshotter — a
    /// weekday or check-in grouping must still reach them, including a
    /// "No check-in" control group so "stressed vs not" is answerable.
    private static func categorizeNonSessionRows(
        _ table: inout [String: [InsightObservation]],
        recipe: InsightRecipe,
        checkins: [InsightCheckinSnapshot],
        calendar: Calendar = .current
    ) {
        guard recipe.shape == .groupComparison,
              let dimension = recipe.dimension,
              dimension == .weekday || dimension == .checkinTag else { return }
        let tagsByDay: [Date: [String]] = Dictionary(
            checkins.map { ($0.date, $0.tags) },
            uniquingKeysWith: { first, second in Array(Set(first + second)) }
        )
        for (id, rows) in table {
            table[id] = rows.flatMap { observation -> [InsightObservation] in
                guard observation.category == nil else { return [observation] }
                switch dimension {
                case .weekday:
                    var copy = observation
                    copy.category = weekdayName(
                        calendar.component(.weekday, from: observation.timestamp), calendar: calendar
                    )
                    return [copy]
                case .checkinTag:
                    let day = calendar.startOfDay(for: observation.timestamp)
                    let categories: [String]
                    if let tags = tagsByDay[day] {
                        categories = tags.isEmpty ? [noTagsCategory] : tags
                    } else {
                        categories = [noCheckinCategory]
                    }
                    return categories.map { tag in
                        var copy = observation
                        copy.category = tag
                        return copy
                    }
                default:
                    return [observation]
                }
            }
        }
    }

    /// The explicit control group: days with no check-in record at all.
    static let noCheckinCategory = "No check-in"
    /// A check-in was made but carried no tags — its own honest state,
    /// distinct from "never checked in".
    static let noTagsCategory = "No tags"

    private static func evaluateDetached(
        recipe: InsightRecipe,
        observations: [String: [InsightObservation]],
        dataStart: Date?,
        now: Date,
        calendar: Calendar
    ) async -> InsightResult {
        let descriptors = InsightMetricCatalog.descriptors(covering: recipe)
        return await Task.detached(priority: .userInitiated) {
            InsightQueryEngine.evaluate(
                recipe: recipe,
                descriptors: descriptors,
                observations: observations,
                now: now,
                calendar: calendar,
                dataStart: dataStart,
                shouldCancel: { Task.isCancelled }
            )
        }.value
    }

    // MARK: - Filters & dimensions

    static func scopedExerciseID(_ recipe: InsightRecipe) -> UUID? {
        recipe.filters
            .first { $0.dimension == .exercise }?
            .values.first
            .flatMap(UUID.init)
    }

    /// Applies canvas filters, then attaches the grouping category. History
    /// from archived routines stays IN — analyzing an old block is a primary
    /// use case, and filters merely narrow, never silently exclude.
    static func filteredSessions(
        _ sessions: [InsightSessionSnapshot],
        recipe: InsightRecipe,
        checkins: [InsightCheckinSnapshot],
        routineNames: [UUID: String] = [:],
        exerciseNames: [UUID: String] = [:],
        calendar: Calendar = .current
    ) -> [InsightSessionSnapshot] {
        var filtered = sessions
        for filter in recipe.filters {
            switch filter.dimension {
            case .exercise:
                let ids = Set(filter.values.compactMap(UUID.init))
                filtered = filtered.filter { !ids.isDisjoint(with: $0.exerciseIDs) }
            case .routine:
                let ids = Set(filter.values.compactMap(UUID.init))
                filtered = filtered.filter { $0.routineID.map(ids.contains) ?? false }
            case .muscle:
                let names = Set(filter.values)
                filtered = filtered.filter { !names.isDisjoint(with: $0.primaryMuscles) }
            case .modality:
                // Match ANY segment's modality, and narrow the segments so a
                // run+cycle workout filtered to "run" contributes only its
                // run — never the whole session under the first segment's
                // flag.
                let names = Set(filter.values)
                filtered = filtered.compactMap { session in
                    let matchingSegments = session.cardioSegments.filter { names.contains($0.modality) }
                    guard names.contains(session.modality) || !matchingSegments.isEmpty else { return nil }
                    var copy = session
                    if !copy.cardioSegments.isEmpty, !matchingSegments.isEmpty {
                        copy.cardioSegments = matchingSegments
                    }
                    return copy
                }
            case .weekday:
                let days = Set(filter.values.compactMap(Int.init))
                filtered = filtered.filter { days.contains($0.weekday) }
            case .source:
                let wantsImported = filter.values.contains("imported")
                let wantsLogged = filter.values.contains("logged")
                filtered = filtered.filter { ($0.isImported && wantsImported) || (!$0.isImported && wantsLogged) }
            case .checkinTag:
                let tags = Set(filter.values)
                let taggedDays = Set(
                    checkins.filter { !tags.isDisjoint(with: $0.tags) }.map(\.date)
                )
                filtered = filtered.filter { taggedDays.contains(calendar.startOfDay(for: $0.startedAt)) }
            }
        }
        guard recipe.shape == .groupComparison, let dimension = recipe.dimension else {
            return filtered
        }
        return categorized(
            filtered, by: dimension, checkins: checkins,
            routineNames: routineNames, exerciseNames: exerciseNames, calendar: calendar
        )
    }

    /// Group membership. Overlapping dimensions (tags, muscles) duplicate the
    /// session into every group it belongs to — groups are compared
    /// independently, never presented as parts of a whole (the donut rule
    /// already excludes them).
    private static func categorized(
        _ sessions: [InsightSessionSnapshot],
        by dimension: InsightDimension,
        checkins: [InsightCheckinSnapshot],
        routineNames: [UUID: String] = [:],
        exerciseNames: [UUID: String] = [:],
        calendar: Calendar
    ) -> [InsightSessionSnapshot] {
        let tagsByDay: [Date: [String]] = Dictionary(
            checkins.map { ($0.date, $0.tags) },
            uniquingKeysWith: { first, second in Array(Set(first + second)) }
        )
        return sessions.flatMap { session -> [InsightSessionSnapshot] in
            let categories: [String]
            switch dimension {
            case .modality:
                // Each SEGMENT groups under its own modality — a run+cycle
                // workout is a running data point AND a cycling one.
                let segmentModalities = Set(session.cardioSegments.map(\.modality))
                categories = segmentModalities.isEmpty ? [session.modality] : segmentModalities.sorted()
            case .weekday: categories = [weekdayName(session.weekday, calendar: calendar)]
            case .source: categories = [session.isImported ? "Imported" : "Logged"]
            case .routine:
                // Group names are user-facing — never a raw UUID.
                categories = [session.routineID.flatMap { routineNames[$0] } ?? "No routine"]
            case .exercise:
                categories = session.exerciseIDs.map { exerciseNames[$0] ?? "Unknown exercise" }
            case .muscle: categories = session.primaryMuscles
            case .checkinTag:
                // Days WITHOUT any check-in record are the explicit control
                // group; a check-in with no tags is its own honest state.
                if let tags = tagsByDay[calendar.startOfDay(for: session.startedAt)] {
                    categories = tags.isEmpty ? [noTagsCategory] : tags
                } else {
                    categories = [noCheckinCategory]
                }
            }
            return categories.map { category in
                var copy = session
                copy.category = category
                if dimension == .modality, !copy.cardioSegments.isEmpty {
                    copy.cardioSegments = copy.cardioSegments.filter { $0.modality == category }
                }
                return copy
            }
        }
    }

    private static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
        let symbols = calendar.weekdaySymbols
        let index = weekday - 1
        return symbols.indices.contains(index) ? symbols[index] : "Day \(weekday)"
    }
}
