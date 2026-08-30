import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Immutable copy of the small portion of a historical set that the live
/// logger needs for placeholders and "Match previous". SwiftData models stay
/// on the worker's context; these value snapshots are safe to hand to SwiftUI.
nonisolated struct LivePreviousSetSnapshot: Equatable, Sendable {
    let setType: SetType
    let weight: Double?
    let addedWeight: Double?
    let assistanceWeight: Double?
    let reps: Int?
    let side2Reps: Int?
    let partialReps: Int?
    let miniReps: [Int]
    let side2MiniReps: [Int]
    let durationSeconds: Int?
    let rpe: Double?
    let rir: Int?

    var modeWeight: Double? {
        switch weightMode {
        case .external: weight
        case .bodyweightAdded: addedWeight
        case .bodyweightAssisted: assistanceWeight
        case .bodyweight: nil
        }
    }

    private let weightMode: WeightMode

    init(set: SetModel) {
        setType = set.setType
        weightMode = set.weightMode
        weight = set.weight
        addedWeight = set.addedWeight
        assistanceWeight = set.assistanceWeight
        reps = set.reps
        side2Reps = set.side2Reps
        partialReps = set.partialReps
        miniReps = set.miniReps
        side2MiniReps = set.side2MiniReps
        durationSeconds = set.durationSeconds
        rpe = set.rpe
        rir = set.rir
    }
}

nonisolated struct LivePreviousCardioSnapshot: Equatable, Sendable {
    let distanceMeters: Double?
    let durationSeconds: Int?
    let averageHeartRate: Int?
}

/// Value-only history used by add/replace exercise pickers. The two counters
/// intentionally preserve their established, slightly different semantics:
/// generic suggestions count every planned row in a completed workout, while
/// replacement ranking counts an exercise at most once per workout and only
/// when a strength set or linked cardio session was actually completed.
nonisolated struct ExercisePickerHistorySnapshot: Equatable, Sendable {
    let completedWorkoutCount: Int
    let latestWorkoutUpdatedAt: Date?
    let occurrenceCountByExerciseID: [UUID: Int]
    let completedWorkoutCountByExerciseID: [UUID: Int]

    static let empty = Self(
        completedWorkoutCount: 0,
        latestWorkoutUpdatedAt: nil,
        occurrenceCountByExerciseID: [:],
        completedWorkoutCountByExerciseID: [:]
    )

    var fingerprint: String {
        "\(completedWorkoutCount)|\((latestWorkoutUpdatedAt ?? .distantPast).timeIntervalSince1970)"
    }

    var swapUsageProfiles: [UUID: ExerciseSwapSuggester.UsageProfile] {
        completedWorkoutCountByExerciseID.mapValues {
            ExerciseSwapSuggester.UsageProfile(completedWorkoutCount: $0)
        }
    }
}

nonisolated struct LiveWorkoutReferenceInput: Equatable, Sendable {
    let workoutID: UUID
    let routineID: UUID?
    let startedAt: Date
    let exerciseIDs: Set<UUID>

    func scoped(to exerciseIDs: Set<UUID>) -> Self {
        Self(
            workoutID: workoutID,
            routineID: routineID,
            startedAt: startedAt,
            exerciseIDs: exerciseIDs
        )
    }
}

nonisolated struct LiveWorkoutPrefillSnapshot: Equatable, Sendable {
    let recordBaselines: [UUID: ExerciseRecordBaseline]
    let previousSetsByExerciseID: [UUID: [LivePreviousSetSnapshot]]
    let previousCardioByExerciseID: [UUID: LivePreviousCardioSnapshot]
}

/// Screen-owned immutable history cache. Completed history does not change
/// during a live workout, so add/replace only needs to load exercise IDs the
/// logger has not seen yet. Retaining prior entries avoids both blanking a
/// replacement that was already loaded and repeating database work.
nonisolated struct LiveWorkoutPrefillCache: Equatable, Sendable {
    private(set) var loadedExerciseIDs = Set<UUID>()
    private(set) var recordBaselines: [UUID: ExerciseRecordBaseline] = [:]
    private(set) var previousSetsByExerciseID: [UUID: [LivePreviousSetSnapshot]] = [:]
    private(set) var previousCardioByExerciseID: [UUID: LivePreviousCardioSnapshot] = [:]

    mutating func merge(_ snapshot: LiveWorkoutPrefillSnapshot) {
        let loaded = Set(snapshot.previousSetsByExerciseID.keys)
        loadedExerciseIDs.formUnion(loaded)
        recordBaselines.merge(snapshot.recordBaselines) { _, latest in latest }
        previousSetsByExerciseID.merge(snapshot.previousSetsByExerciseID) { _, latest in latest }
        previousCardioByExerciseID.merge(snapshot.previousCardioByExerciseID) { _, latest in latest }
    }

    func missingExerciseIDs(from requested: Set<UUID>) -> Set<UUID> {
        requested.subtracting(loadedExerciseIDs)
    }
}

nonisolated struct LiveWorkoutReferenceSnapshot: Equatable, Sendable {
    let recordBaselines: [UUID: ExerciseRecordBaseline]
    let previousSetsByExerciseID: [UUID: [LivePreviousSetSnapshot]]
    let previousCardioByExerciseID: [UUID: LivePreviousCardioSnapshot]
    let pickerHistory: ExercisePickerHistorySnapshot
}

/// One semantic request token for the logger's screen-owned history task.
/// A token is valid only while it is the latest generation *and* the current
/// workout input still matches, preventing a slow canceled scan from applying
/// results after add/remove/replace changed the workout graph.
nonisolated struct LiveWorkoutReferenceRequestGate: Sendable {
    struct Request: Equatable, Sendable {
        let generation: UInt64
        let input: LiveWorkoutReferenceInput
    }

    struct BeginResult: Equatable, Sendable {
        let request: Request
        let startsNewWork: Bool
    }

    private var generation: UInt64 = 0
    private var activeRequest: Request?

    mutating func begin(_ input: LiveWorkoutReferenceInput) -> BeginResult {
        if let activeRequest, activeRequest.input == input {
            return BeginResult(request: activeRequest, startsNewWork: false)
        }
        generation &+= 1
        let request = Request(generation: generation, input: input)
        activeRequest = request
        return BeginResult(request: request, startsNewWork: true)
    }

    func shouldApply(
        _ request: Request,
        currentInput: LiveWorkoutReferenceInput
    ) -> Bool {
        request == activeRequest && request.input == currentInput
    }

    @discardableResult
    mutating func finish(_ request: Request) -> Bool {
        guard request == activeRequest else { return false }
        activeRequest = nil
        return true
    }

    mutating func cancel() {
        generation &+= 1
        activeRequest = nil
    }
}

nonisolated struct LiveRoutineProgressionSnapshot: Equatable, Sendable {
    let progressionRuleJSON: String?
    let targetRepsLow: Int?
    let targetRepsHigh: Int?
}

/// History-only inputs for the completion sheet. The active workout remains
/// MainActor-owned so unsaved field drafts are reflected immediately; this
/// projection supplies the expensive, immutable historical half of the work.
nonisolated struct PostWorkoutHistoryInput: Equatable, Sendable {
    let workoutID: UUID
    let routineID: UUID?
    let title: String?
    let startedAt: Date
}

nonisolated struct PostWorkoutModalityHistorySnapshot: Equatable, Sendable {
    struct ConditioningBaseline: Equatable, Sendable {
        var bestElapsedSeconds: Int?
        var bestScore: Double?
        var fastestRoundSeconds: Int?
        var bestLoad: Double?
    }

    struct YogaBaseline: Equatable, Sendable {
        var longestDurationSeconds: Int?
        var mostPoses: Int?
    }

    var conditioningBaselines: [String: ConditioningBaseline] = [:]
    var yogaBaselines: [YogaStyle: YogaBaseline] = [:]
    var yogaPracticeDays: Set<Date> = []
}

nonisolated struct PostWorkoutHistorySnapshot: Sendable {
    let previousComparableVolume: Double?
    let recordBaselines: [UUID: ExerciseRecordBaseline]
    let modalityHistory: PostWorkoutModalityHistorySnapshot
    let routineProgressionByExerciseID: [UUID: LiveRoutineProgressionSnapshot]

    static let empty = Self(
        previousComparableVolume: nil,
        recordBaselines: [:],
        modalityHistory: .init(),
        routineProgressionByExerciseID: [:]
    )
}

/// Reads completed workout history on a detached SwiftData context and returns
/// only immutable projections. No `PersistentModel` crosses the concurrency
/// boundary, and initial logger presentation no longer faults every historical
/// workout relationship on MainActor.
nonisolated struct LiveWorkoutHistoryWorker: Sendable {
    let modelContainer: ModelContainer

    func referenceSnapshot(
        for input: LiveWorkoutReferenceInput
    ) async throws -> LiveWorkoutReferenceSnapshot {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let prefill = try Self.makePrefillSnapshot(input: input, in: context)
            let history = try Self.completedHistory(in: context, excluding: input.workoutID)
            return LiveWorkoutReferenceSnapshot(
                recordBaselines: prefill.recordBaselines,
                previousSetsByExerciseID: prefill.previousSetsByExerciseID,
                previousCardioByExerciseID: prefill.previousCardioByExerciseID,
                pickerHistory: try Self.makePickerHistorySnapshot(history: history)
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    /// User-visible "Previous" and ghost values are interaction-critical. Query
    /// only rows belonging to the requested exercises and return them ahead of
    /// slower all-history picker analytics. The isolated context keeps every
    /// relationship fault off MainActor without making a large history delay
    /// the logger's functional state.
    func prefillSnapshot(
        for input: LiveWorkoutReferenceInput
    ) async throws -> LiveWorkoutPrefillSnapshot {
        let container = modelContainer
        let task = Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try Self.makePrefillSnapshot(input: input, in: context)
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    /// Picker ranking is useful but not required for the logger's first usable
    /// state. It remains a single utility-priority history projection and is
    /// retained for the whole workout rather than restarting after add/replace.
    func pickerHistorySnapshot(
        excluding workoutID: UUID
    ) async throws -> ExercisePickerHistorySnapshot {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let history = try Self.completedHistory(in: context, excluding: workoutID)
            return try Self.makePickerHistorySnapshot(history: history)
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    func postWorkoutHistorySnapshot(
        for input: PostWorkoutHistoryInput
    ) async throws -> PostWorkoutHistorySnapshot {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let history = try Self.completedHistory(in: context, excluding: input.workoutID)
            try Task.checkCancellation()

            let comparable = history.first { workout in
                if let routineID = input.routineID {
                    return workout.routineID == routineID
                }
                return workout.title == input.title
            }
            let previousComparableVolume = comparable.map {
                $0.exercises.flatMap(\.sets).reduce(0) { total, set in
                    total + (set.completedAt == nil ? 0 : (set.totalVolume ?? 0))
                }
            }

            var baselines: [UUID: ExerciseRecordBaseline] = [:]
            var seen = Set<UUID>()
            var chronological: [WorkoutModel] = []
            for workout in history.reversed()
            where workout.startedAt < input.startedAt && seen.insert(workout.id).inserted {
                chronological.append(workout)
                for workoutExercise in workout.exercises {
                    var baseline = baselines[workoutExercise.exerciseID] ?? ExerciseRecordBaseline()
                    for set in workoutExercise.sets { baseline.absorb(set) }
                    baselines[workoutExercise.exerciseID] = baseline
                }
                try Task.checkCancellation()
            }
            let modalityHistory = try Self.makeModalityHistory(
                workouts: chronological
            )

            let routineProgression = try Self.routineProgression(
                routineID: input.routineID,
                in: context
            )
            return PostWorkoutHistorySnapshot(
                previousComparableVolume: previousComparableVolume,
                recordBaselines: baselines,
                modalityHistory: modalityHistory,
                routineProgressionByExerciseID: routineProgression
            )
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    /// Identifies only completed workouts that contain the requested exercise.
    /// The relationship walk stays on the worker context; the destination view
    /// can then fetch this usually-small ID set on MainActor without loading or
    /// scanning the user's entire workout graph.
    func completedWorkoutIDs(
        containing exerciseID: UUID
    ) async throws -> [UUID] {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let history = try Self.completedHistory(in: context, excluding: nil)
            var ids: [UUID] = []
            for workout in history {
                if workout.exercises.contains(where: { $0.exerciseID == exerciseID }) {
                    ids.append(workout.id)
                }
                try Task.checkCancellation()
            }
            return ids
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    /// Identifies every completed workout containing the exact conditioning
    /// prescription (or its established reference/legacy lineage). Preset
    /// analytics and rename-on-edit must never be truncated to a recent-window
    /// approximation, but discovering the usually-small matching ID set does
    /// not belong on MainActor or on the live logger's first frame.
    func completedWorkoutIDs(
        matchingConditioning section: ConditioningSection
    ) async throws -> [UUID] {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let history = try Self.completedHistory(in: context, excluding: nil)
            let matcher = ConditioningPresetHistoryMatcher(source: section)
            return history.compactMap { workout in
                matcher.workoutContainsMatchingPlan(workout) ? workout.id : nil
            }
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    /// Parent-only lookup used when an explicit historical workout drill-in
    /// needs the same complete comparison context it had before the logger's
    /// render path was optimized. Relationship traversal remains deferred
    /// until the user actually opens that detail screen.
    func completedWorkoutIDs() async throws -> [UUID] {
        let container = modelContainer
        let task = Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            return try Self.completedHistory(in: context, excluding: nil).map(\.id)
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() }
        )
    }

    #if DEBUG
    func isExecutingOnMainThreadForTesting() async -> Bool {
        let container = modelContainer
        return await Task.detached(priority: .utility) {
            _ = ModelContext(container)
            return Self.currentThreadIsMain()
        }.value
    }

    private static func currentThreadIsMain() -> Bool { Thread.isMainThread }
    #endif

    private static func completedHistory(
        in context: ModelContext,
        excluding workoutID: UUID?
    ) throws -> [WorkoutModel] {
        let workouts = try context.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt != nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))
        try Task.checkCancellation()
        guard let workoutID else { return workouts }
        return workouts.filter { $0.id != workoutID }
    }

    private static func makePrefillSnapshot(
        input: LiveWorkoutReferenceInput,
        in context: ModelContext
    ) throws -> LiveWorkoutPrefillSnapshot {
        var baselines: [UUID: ExerciseRecordBaseline] = [:]
        var previousSets = Dictionary(
            uniqueKeysWithValues: input.exerciseIDs.map { ($0, [LivePreviousSetSnapshot]()) }
        )
        var previousCardio: [UUID: LivePreviousCardioSnapshot] = [:]
        let requestedExerciseIDs = Array(input.exerciseIDs)
        let matchingRows: [WorkoutExerciseModel]
        if requestedExerciseIDs.isEmpty {
            matchingRows = []
        } else {
            matchingRows = try context.fetch(FetchDescriptor<WorkoutExerciseModel>(
                predicate: #Predicate { requestedExerciseIDs.contains($0.exerciseID) }
            ))
        }
        let rowsByExerciseID = Dictionary(grouping: matchingRows, by: \WorkoutExerciseModel.exerciseID)
        for exerciseID in input.exerciseIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            let eligible = (rowsByExerciseID[exerciseID] ?? []).filter { row in
                guard let workout = row.workout else { return false }
                return workout.id != input.workoutID
                    && workout.endedAt != nil
                    && workout.deletedAt == nil
            }
            let chronological = eligible.sorted(by: rowNewestFirst)

            for row in chronological {
                guard let workout = row.workout, workout.startedAt < input.startedAt else { continue }
                var baseline = baselines[exerciseID] ?? ExerciseRecordBaseline()
                for set in row.sets { baseline.absorb(set) }
                baselines[exerciseID] = baseline
            }

            let routineRows: [WorkoutExerciseModel]
            if let routineID = input.routineID {
                routineRows = chronological.filter { $0.workout?.routineID == routineID }
            } else {
                routineRows = []
            }
            let routineRowIDs = Set(routineRows.map(\.id))
            let ordered = routineRows + chronological.filter { !routineRowIDs.contains($0.id) }
            var unresolvedTypes = Set(SetType.allCases.map(\.rawValue))
            for row in ordered where !unresolvedTypes.isEmpty {
                let completed = row.sets
                    .filter { $0.completedAt != nil }
                    .sorted { $0.position < $1.position }
                for type in SetType.allCases where unresolvedTypes.contains(type.rawValue) {
                    let matching = completed.filter { $0.setType == type }
                    guard !matching.isEmpty else { continue }
                    previousSets[exerciseID, default: []].append(
                        contentsOf: matching.map(LivePreviousSetSnapshot.init(set:))
                    )
                    unresolvedTypes.remove(type.rawValue)
                }
                try Task.checkCancellation()
            }

            // Cardio's established contract is chronological, not routine-first:
            // "Last time" means the newest completed session of that exercise.
            for row in chronological {
                guard let workout = row.workout,
                      let session = workout.cardioSessions.first(where: {
                    $0.workoutExerciseID == row.id
                        && $0.endedAt != nil
                        && $0.deletedAt == nil
                }) else { continue }
                previousCardio[exerciseID] = LivePreviousCardioSnapshot(
                    distanceMeters: session.distanceMeters,
                    durationSeconds: session.durationSeconds,
                    averageHeartRate: session.avgHR
                )
                break
            }
            try Task.checkCancellation()
        }

        return LiveWorkoutPrefillSnapshot(
            recordBaselines: baselines,
            previousSetsByExerciseID: previousSets,
            previousCardioByExerciseID: previousCardio
        )
    }

    private static func rowNewestFirst(
        _ lhs: WorkoutExerciseModel,
        _ rhs: WorkoutExerciseModel
    ) -> Bool {
        guard let lhsWorkout = lhs.workout, let rhsWorkout = rhs.workout else {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if lhsWorkout.startedAt != rhsWorkout.startedAt {
            return lhsWorkout.startedAt > rhsWorkout.startedAt
        }
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func makePickerHistorySnapshot(
        history: [WorkoutModel]
    ) throws -> ExercisePickerHistorySnapshot {
        var occurrenceCountByExerciseID: [UUID: Int] = [:]
        var completedWorkoutCountByExerciseID: [UUID: Int] = [:]
        var latestUpdatedAt: Date?

        for workout in history {
            latestUpdatedAt = max(latestUpdatedAt ?? workout.updatedAt, workout.updatedAt)
            let completedCardioRowIDs = Set(
                workout.cardioSessions.compactMap { session -> UUID? in
                    guard session.endedAt != nil, session.deletedAt == nil else { return nil }
                    return session.workoutExerciseID
                }
            )
            var completedExerciseIDs = Set<UUID>()
            for workoutExercise in workout.exercises {
                occurrenceCountByExerciseID[workoutExercise.exerciseID, default: 0] += 1
                if workoutExercise.sets.contains(where: { $0.completedAt != nil })
                    || completedCardioRowIDs.contains(workoutExercise.id) {
                    completedExerciseIDs.insert(workoutExercise.exerciseID)
                }
            }
            for exerciseID in completedExerciseIDs {
                completedWorkoutCountByExerciseID[exerciseID, default: 0] += 1
            }
            try Task.checkCancellation()
        }

        return ExercisePickerHistorySnapshot(
            completedWorkoutCount: history.count,
            latestWorkoutUpdatedAt: latestUpdatedAt,
            occurrenceCountByExerciseID: occurrenceCountByExerciseID,
            completedWorkoutCountByExerciseID: completedWorkoutCountByExerciseID
        )
    }

    private static func routineProgression(
        routineID: UUID?,
        in context: ModelContext
    ) throws -> [UUID: LiveRoutineProgressionSnapshot] {
        guard let routineID else { return [:] }
        let routines = try context.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID && $0.deletedAt == nil }
        ))
        guard let routine = routines.first else { return [:] }
        return Dictionary(
            routine.exercises.map { routineExercise in
                let lows = routineExercise.sets.compactMap(\.targetRepsLow)
                let highs = routineExercise.sets.compactMap(\.targetRepsHigh)
                return (
                    routineExercise.id,
                    LiveRoutineProgressionSnapshot(
                        progressionRuleJSON: routineExercise.progressionRuleJSON,
                        targetRepsLow: lows.min(),
                        targetRepsHigh: highs.max()
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private struct ConditioningActivity {
        let key: String
        let section: ConditioningSection
        let result: ConditioningSectionResult
    }

    private static func makeModalityHistory(
        workouts: [WorkoutModel]
    ) throws -> PostWorkoutModalityHistorySnapshot {
        var output = PostWorkoutModalityHistorySnapshot()
        let calendar = Calendar.current
        for workout in workouts {
            for activity in conditioningActivities(in: workout) where activity.result.completed {
                var baseline = output.conditioningBaselines[activity.key] ?? .init()
                let result = activity.result
                if result.scoreKind == .elapsedTime,
                   let elapsed = result.elapsedSeconds,
                   elapsed > 0 {
                    baseline.bestElapsedSeconds = min(baseline.bestElapsedSeconds ?? elapsed, elapsed)
                }
                if let score = conditioningScoreMetric(result), score > 0 {
                    baseline.bestScore = max(baseline.bestScore ?? score, score)
                }
                if let fastest = ConditioningPerformanceAnalysis(
                    section: activity.section,
                    result: result
                ).fastestRoundSeconds, fastest > 0 {
                    baseline.fastestRoundSeconds = min(
                        baseline.fastestRoundSeconds ?? fastest,
                        fastest
                    )
                }
                if result.scoreKind == .load, let load = result.load, load > 0 {
                    baseline.bestLoad = max(baseline.bestLoad ?? load, load)
                }
                output.conditioningBaselines[activity.key] = baseline
            }

            for session in yogaSessions(in: workout) {
                let plan = yogaPlan(for: session, workout: workout)
                let style = session.resolvedYogaStyle
                let duration = max(0, session.durationSeconds ?? 0)
                let poses = session.logicalYogaPosesCompleted ?? plan?.steps.count ?? 0
                var baseline = output.yogaBaselines[style] ?? .init()
                if duration > 0 {
                    baseline.longestDurationSeconds = max(
                        baseline.longestDurationSeconds ?? duration,
                        duration
                    )
                }
                if poses > 0 {
                    baseline.mostPoses = max(baseline.mostPoses ?? poses, poses)
                }
                output.yogaBaselines[style] = baseline
                if duration >= 60 {
                    output.yogaPracticeDays.insert(calendar.startOfDay(for: workout.startedAt))
                }
            }
            try Task.checkCancellation()
        }
        return output
    }

    private static func conditioningActivities(in workout: WorkoutModel) -> [ConditioningActivity] {
        let contexts: [(ConditioningPlan, ConditioningResult?)] = {
            let blocks = workout.blocks
                .filter { $0.kind == .conditioning }
                .sorted { $0.position < $1.position }
                .compactMap { block -> (ConditioningPlan, ConditioningResult?)? in
                    guard let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) else {
                        return nil
                    }
                    return (plan, ConditioningResult.decode(from: block.resultJSON))
                }
            if !blocks.isEmpty { return blocks }
            guard let plan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON) else {
                return []
            }
            return [(plan, ConditioningResult.decode(from: workout.conditioningResultJSON))]
        }()

        return contexts.flatMap { plan, result in
            let results = result?.sectionResults ?? []
            return plan.sections.enumerated().compactMap { index, section -> ConditioningActivity? in
                let indexed = results.indices.contains(index) ? results[index] : nil
                guard let result = results.first(where: { $0.id == section.id }) ?? indexed else {
                    return nil
                }
                return ConditioningActivity(
                    key: conditioningPrescriptionKey(section),
                    section: section,
                    result: result
                )
            }
        }
    }

    private static func conditioningPrescriptionKey(_ section: ConditioningSection) -> String {
        let movements = section.movements.map { movement in
            [
                movement.exerciseID.uuidString,
                String(movement.targetValue.bitPattern),
                movement.targetUnit.rawValue,
                movement.targetLoad.map { String($0.bitPattern) } ?? "nil",
                movement.weightMode.rawValue
            ].joined(separator: ":")
        }.joined(separator: ";")
        var components: [String] = []
        components.append(section.format.rawValue)
        components.append(section.ordering.rawValue)
        components.append(section.scoreKind.rawValue)
        components.append(section.durationSeconds.map(String.init) ?? "nil")
        components.append(section.timeCapSeconds.map(String.init) ?? "nil")
        components.append(section.rounds.map(String.init) ?? "nil")
        components.append(section.intervalSeconds.map(String.init) ?? "nil")
        components.append(section.workSeconds.map(String.init) ?? "nil")
        components.append(section.restSeconds.map(String.init) ?? "nil")
        components.append(section.repScheme.map(String.init).joined(separator: ","))
        components.append(section.ladderStep.map(String.init) ?? "nil")
        components.append(String(section.endsOnFailure))
        components.append(String(section.restartEachInterval))
        components.append(movements)
        return components.joined(separator: "|")
    }

    private static func conditioningScoreMetric(_ result: ConditioningSectionResult) -> Double? {
        switch result.scoreKind {
        case .elapsedTime, .load: nil
        case .roundsAndReps: result.totalReps.map(Double.init) ?? result.fullRounds.map(Double.init)
        case .totalReps: result.totalReps.map(Double.init)
        case .completedIntervals: (result.completedIntervals ?? result.fullRounds).map(Double.init)
        }
    }

    private static func yogaSessions(in workout: WorkoutModel) -> [CardioSessionModel] {
        workout.cardioSessions.filter { session in
            guard session.deletedAt == nil, session.endedAt != nil, session.isYogaSession else {
                return false
            }
            if let blockID = session.workoutBlockID,
               let block = workout.blocks.first(where: { $0.id == blockID }) {
                return block.kind == .yoga
            }
            return session.sourceDevice?.contains("conditioning") != true
        }
    }

    private static func yogaPlan(
        for session: CardioSessionModel,
        workout: WorkoutModel
    ) -> YogaFlowPlan? {
        if let blockID = session.workoutBlockID,
           let block = workout.blocks.first(where: { $0.id == blockID }) {
            return YogaFlowPlan.decode(from: block.planSnapshotJSON)
        }
        if let exerciseID = session.workoutExerciseID,
           let exercise = workout.exercises.first(where: { $0.id == exerciseID }) {
            return YogaFlowPlan.decode(from: exercise.yogaFlowJSON)
        }
        return nil
    }
}
