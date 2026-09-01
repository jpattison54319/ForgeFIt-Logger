import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Immutable identity and value snapshot handed to App Intents before Siri
/// asks follow-up questions. Mutations revalidate the whole revision so a
/// delayed answer can never overwrite a set edited on iPhone or Apple Watch.
nonisolated struct ForgeFitActiveSetSnapshot: Equatable, Sendable {
    struct Revision: Equatable, Sendable {
        let updatedAt: Date
        let completedAt: Date?
        let reps: Int?
        let loadKilograms: Double?
        let rpe: Double?
        let rir: Int?
        let partialReps: Int?
    }

    let workoutID: UUID
    let workoutTitle: String
    let workoutExerciseID: UUID
    let setID: UUID
    let exerciseName: String
    let setLabel: String
    let setType: SetType
    let weightMode: WeightMode
    let displayUnit: WeightUnit
    let reps: Int?
    let loadKilograms: Double?
    let rpe: Double?
    let rir: Int?
    let partialReps: Int?
    let isCompleted: Bool
    let completedSetCount: Int
    let totalSetCount: Int
    let logsEffort: Bool
    let defaultsToFailure: Bool
    let needsSpecializedUI: Bool
    let revision: Revision

    var identifier: String {
        "\(workoutID.uuidString.lowercased()):\(setID.uuidString.lowercased())"
    }

    var spokenName: String {
        "\(exerciseName) \(setLabel)"
    }
}

nonisolated struct ForgeFitSetCommandValues: Equatable, Sendable {
    var reps: Int?
    var loadKilograms: Double?
    var rpe: Double?
    var rir: Int?
    var partialReps: Int?

    var hasAnyValue: Bool {
        reps != nil || loadKilograms != nil || rpe != nil || rir != nil || partialReps != nil
    }
}

nonisolated struct ForgeFitWorkoutFinishPreview: Equatable, Sendable {
    struct SetState: Equatable, Sendable {
        let id: UUID
        let updatedAt: Date
        let completedAt: Date?
        let setTypeRaw: String
        let weightModeRaw: String
        let reps: Int?
        let weight: Double?
        let addedWeight: Double?
        let assistanceWeight: Double?
        let rpe: Double?
        let rir: Int?
        let durationSeconds: Int?
        let holdSeconds: Int?
        let partialReps: Int?
        let miniRepsJSON: String?
        let side2Reps: Int?
        let side2MiniRepsJSON: String?
    }

    struct ExerciseState: Equatable, Sendable {
        let id: UUID
        let updatedAt: Date
        let exerciseID: UUID
        let position: Int
        let notes: String?
        let restSeconds: Int?
        let supersetGroup: Int?
    }

    struct SessionState: Equatable, Sendable {
        let id: UUID
        let updatedAt: Date
        let liveStartedAt: Date?
        let endedAt: Date?
    }

    struct BlockState: Equatable, Sendable {
        let id: UUID
        let updatedAt: Date
        let progressJSON: String?
        let resultJSON: String?
    }

    struct Revision: Equatable, Sendable {
        let workoutUpdatedAt: Date
        let workoutTitle: String?
        let workoutNotes: String?
        let exercises: [ExerciseState]
        let sets: [SetState]
        let sessions: [SessionState]
        let blocks: [BlockState]
    }

    let workoutID: UUID
    let title: String
    let completedSetCount: Int
    let totalSetCount: Int
    let incompleteMessage: String
    let hasSubstance: Bool
    let revision: Revision
}

nonisolated struct ForgeFitActiveWorkoutCommandError: Error, Equatable, Sendable {
    let message: String
}

/// The single active-workout command boundary used by Siri and Shortcuts.
/// It owns no transcript or donated workout data; every query resolves live
/// against the local SwiftData store and returns only value snapshots.
final class ForgeFitActiveWorkoutIntentService: @unchecked Sendable {
    private let container: ModelContainer
    nonisolated(unsafe) private let defaults: UserDefaults
    private let now: @MainActor () -> Date
    private let finishEffects: WorkoutFinisher.FinishEffects?
    private let publishesExternalSurfaces: Bool

    nonisolated init(
        container: ModelContainer,
        defaults: UserDefaults = .standard,
        now: @escaping @MainActor () -> Date = { .now },
        finishEffects: WorkoutFinisher.FinishEffects? = nil,
        publishesExternalSurfaces: Bool = true
    ) {
        self.container = container
        self.defaults = defaults
        self.now = now
        self.finishEffects = finishEffects
        self.publishesExternalSurfaces = publishesExternalSurfaces
    }

    @MainActor
    func activeSetSnapshots() -> [ForgeFitActiveSetSnapshot] {
        guard let workout = activeWorkout() else { return [] }
        return snapshots(in: workout)
    }

    @MainActor
    func setSnapshot(identifier: String) -> ForgeFitActiveSetSnapshot? {
        activeSetSnapshots().first { $0.identifier == identifier }
    }

    @MainActor
    func nextPendingSet() -> ForgeFitActiveSetSnapshot? {
        activeSetSnapshots().first { !$0.isCompleted }
    }

    @MainActor
    func mostRecentlyCompletedSet() -> ForgeFitActiveSetSnapshot? {
        guard let workout = activeWorkout() else { return nil }
        let completedIDs = workout.exercises
            .flatMap(\.sets)
            .compactMap { set in set.completedAt.map { (set.id, $0) } }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.uuidString < $1.0.uuidString
            }
            .map(\.0)
        let byID = Dictionary(
            uniqueKeysWithValues: snapshots(in: workout).map { ($0.setID, $0) }
        )
        return completedIDs.lazy.compactMap { byID[$0] }.first
    }

    @MainActor
    func statusText() -> String {
        guard let workout = activeWorkout() else {
            return "No ForgeFit workout is active. You can ask to start your next workout."
        }

        let snapshots = snapshots(in: workout)
        let completed = snapshots.filter(\.isCompleted).count
        let title = workout.title ?? "Workout"
        let progress = "\(title): \(completed) of \(snapshots.count) sets complete."
        let timer = RestTimerController.shared
        let rest: String? = if timer.isRunning {
            timer.isMicro
                ? "A structured-set timer has \(durationText(timer.remaining())) remaining."
                : "Rest has \(durationText(timer.remaining())) remaining."
        } else {
            nil
        }

        if let next = snapshots.first(where: { !$0.isCompleted }) {
            let target = targetText(for: next)
            let nextText: String
            if next.needsSpecializedUI {
                nextText = "Next is \(next.spokenName). Open ForgeFit for its dedicated controls."
            } else {
                nextText = "Next is \(next.spokenName): \(target)."
            }
            return [progress, rest, nextText].compactMap { $0 }.joined(separator: " ")
        }

        if hasUnfinishedSessionWork(in: workout) {
            return [progress, rest, "Continue the active cardio, yoga, or conditioning controls in ForgeFit."]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return [progress, rest, "All logged sets are complete. You can finish the workout when you're ready."]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    @MainActor
    func completeSet(
        expected snapshot: ForgeFitActiveSetSnapshot,
        values: ForgeFitSetCommandValues
    ) throws -> ForgeFitActiveSetSnapshot {
        let resolved = try resolveSet(expected: snapshot)
        let workout = resolved.workout
        let workoutExercise = resolved.workoutExercise
        let set = resolved.set
        guard set.completedAt == nil else {
            throw commandError("\(snapshot.spokenName) is already complete. I didn't advance another set.")
        }
        guard !needsSpecializedUI(set: set, workoutExercise: workoutExercise) else {
            throw commandError("\(snapshot.spokenName) needs ForgeFit's dedicated live controls.")
        }
        guard let reps = values.reps else {
            throw commandError("Reps are required before this set can be completed.")
        }
        try validate(reps: reps)
        try validateLoad(values.loadKilograms, for: set.weightMode, required: true)
        try validateEffort(values, preferences: WorkoutEffortPolicy.current(defaults: defaults))
        if set.setType.tracksTrailingPartials, values.partialReps == nil {
            throw commandError("Lengthened partial reps are required before this extended set can be completed.")
        }
        if let partialReps = values.partialReps { try validate(reps: partialReps) }

        let previous = SetMutationState(set: set)
        let previousWorkoutVolume = workout.totalVolume
        let previousWorkoutUpdatedAt = workout.updatedAt
        set.reps = reps
        if set.weightMode != .bodyweight {
            set.setModeWeight(values.loadKilograms)
        }
        if set.setType.tracksTrailingPartials {
            set.partialReps = values.partialReps
        }
        applyEffort(values, to: set)
        let completedAt = now()
        LiveSetCompletion.prepare(
            set,
            completedAt: completedAt,
            latestBodyweight: HealthMetricsStore.shared.latestBodyweight
        )
        set.updatedAt = completedAt
        workout.recomputeTotalVolume()
        workout.updatedAt = completedAt

        do {
            try container.mainContext.save()
        } catch {
            previous.restore(set)
            workout.totalVolume = previousWorkoutVolume
            workout.updatedAt = previousWorkoutUpdatedAt
            throw commandError("ForgeFit couldn't save that set. It is still incomplete.")
        }

        startRestIfNeeded(after: set, in: workoutExercise, active: workout)
        publish(workout: workout)
        guard let committed = snapshots(in: workout).first(where: { $0.setID == set.id }) else {
            throw commandError("The set was saved, but ForgeFit couldn't reload its current status.")
        }
        return committed
    }

    @MainActor
    func updateSet(
        expected snapshot: ForgeFitActiveSetSnapshot,
        values: ForgeFitSetCommandValues
    ) throws -> ForgeFitActiveSetSnapshot {
        guard values.hasAnyValue else {
            throw commandError("Tell me which reps, load, RPE, RIR, or partial reps to update.")
        }
        let resolved = try resolveSet(expected: snapshot)
        let workout = resolved.workout
        let workoutExercise = resolved.workoutExercise
        let set = resolved.set
        guard !needsSpecializedUI(set: set, workoutExercise: workoutExercise) else {
            throw commandError("\(snapshot.spokenName) needs ForgeFit's dedicated live controls.")
        }
        if let reps = values.reps { try validate(reps: reps) }
        if let partials = values.partialReps { try validate(reps: partials) }
        try validateLoad(values.loadKilograms, for: set.weightMode, required: false)
        try validateEffort(values, preferences: WorkoutEffortPolicy.current(defaults: defaults))
        if values.partialReps != nil, !set.setType.tracksTrailingPartials {
            throw commandError("\(snapshot.spokenName) doesn't have a lengthened-partials field.")
        }

        let previous = SetMutationState(set: set)
        let previousWorkoutVolume = workout.totalVolume
        let previousWorkoutUpdatedAt = workout.updatedAt
        if let reps = values.reps { set.reps = reps }
        if let load = values.loadKilograms, set.weightMode != .bodyweight {
            set.setModeWeight(load)
        }
        if let partials = values.partialReps { set.partialReps = partials }
        if values.rpe != nil || values.rir != nil { applyEffort(values, to: set) }
        let changedAt = now()
        set.recomputeDerivedMetrics()
        set.updatedAt = changedAt
        workout.recomputeTotalVolume()
        workout.updatedAt = changedAt

        do {
            try container.mainContext.save()
        } catch {
            previous.restore(set)
            workout.totalVolume = previousWorkoutVolume
            workout.updatedAt = previousWorkoutUpdatedAt
            throw commandError("ForgeFit couldn't save those set changes. The previous values are unchanged.")
        }

        publish(workout: workout)
        guard let committed = snapshots(in: workout).first(where: { $0.setID == set.id }) else {
            throw commandError("The set was saved, but ForgeFit couldn't reload its current status.")
        }
        return committed
    }

    @MainActor
    func reopenSet(
        expected snapshot: ForgeFitActiveSetSnapshot
    ) throws -> ForgeFitActiveSetSnapshot {
        let resolved = try resolveSet(expected: snapshot)
        let workout = resolved.workout
        let workoutExercise = resolved.workoutExercise
        let set = resolved.set
        guard !needsSpecializedUI(set: set, workoutExercise: workoutExercise) else {
            throw commandError("\(snapshot.spokenName) needs ForgeFit's dedicated live controls.")
        }
        guard set.completedAt != nil else {
            throw commandError("\(snapshot.spokenName) is already incomplete. I didn't reopen another set.")
        }

        let previous = SetMutationState(set: set)
        let previousWorkoutVolume = workout.totalVolume
        let previousWorkoutUpdatedAt = workout.updatedAt
        let changedAt = now()
        set.completedAt = nil
        set.recomputeDerivedMetrics()
        set.updatedAt = changedAt
        workout.recomputeTotalVolume()
        workout.updatedAt = changedAt

        do {
            try container.mainContext.save()
        } catch {
            previous.restore(set)
            workout.totalVolume = previousWorkoutVolume
            workout.updatedAt = previousWorkoutUpdatedAt
            throw commandError("ForgeFit couldn't reopen that set. It remains complete.")
        }

        publish(workout: workout)
        guard let reopened = snapshots(in: workout).first(where: { $0.setID == set.id }) else {
            throw commandError("The set was reopened, but ForgeFit couldn't reload its current status.")
        }
        return reopened
    }

    @MainActor
    func restStatusText() -> String {
        guard activeWorkout() != nil else {
            return "No ForgeFit workout is active."
        }
        let timer = RestTimerController.shared
        guard timer.isRunning else {
            return "No rest timer is running."
        }
        let kind = timer.isMicro ? "structured-set timer" : "rest timer"
        return "Your \(kind) has \(durationText(timer.remaining())) remaining."
    }

    @MainActor
    func skipOrdinaryRest() throws -> String {
        let workout = try workoutForRestMutation()
        let timer = RestTimerController.shared
        guard timer.isRunning else { return "No rest timer is running." }
        guard !timer.isMicro else {
            throw commandError("That timer belongs to a structured set. Open ForgeFit for its dedicated controls.")
        }
        timer.skip()
        publish(workout: workout)
        return "Rest skipped."
    }

    @MainActor
    func adjustOrdinaryRest(by seconds: Int) throws -> String {
        let workout = try workoutForRestMutation()
        let timer = RestTimerController.shared
        guard timer.isRunning else { return "No rest timer is running." }
        guard !timer.isMicro else {
            throw commandError("That timer belongs to a structured set. Open ForgeFit for its dedicated controls.")
        }
        timer.adjust(by: seconds)
        publish(workout: workout)
        return "Rest now has \(durationText(timer.remaining())) remaining."
    }

    @MainActor
    func finishPreview() throws -> ForgeFitWorkoutFinishPreview {
        do {
            if container.mainContext.hasChanges { try container.mainContext.save() }
        } catch {
            throw commandError("ForgeFit couldn't save the latest workout edits, so the workout is still active.")
        }
        guard let workout = activeWorkout() else {
            throw commandError("No ForgeFit workout is active.")
        }
        if let blocker = WorkoutFinisher.conditioningTargetBlocker(in: workout) {
            throw commandError(blocker)
        }
        return makeFinishPreview(workout)
    }

    @MainActor
    func finishWorkout(
        expected preview: ForgeFitWorkoutFinishPreview,
        exertion: Int?
    ) throws {
        do {
            if container.mainContext.hasChanges { try container.mainContext.save() }
        } catch {
            throw commandError("ForgeFit couldn't save the latest workout edits, so the workout is still active.")
        }
        guard let workout = activeWorkout(), workout.id == preview.workoutID else {
            throw commandError("The active workout changed while Siri was confirming. I didn't finish a workout.")
        }
        let current = makeFinishPreview(workout)
        guard current.revision == preview.revision else {
            throw commandError("The workout changed while Siri was confirming. Review it and ask again to finish.")
        }
        if let blocker = WorkoutFinisher.conditioningTargetBlocker(in: workout) {
            throw commandError(blocker)
        }
        if current.hasSubstance {
            guard let exertion, (0...10).contains(exertion) else {
                throw commandError("Choose a whole-session exertion from 0 to 10 before finishing.")
            }
        }

        let ratedAt = current.hasSubstance ? now() : nil
        let summary = current.hasSubstance
            ? WorkoutFinisher.SummaryCommit(
                wholeSessionRPE: exertion.map(Double.init),
                wholeSessionRPERatedAt: ratedAt,
                wholeSessionRPEProtocolVersion: "whole-session-cr10-immediate-v1",
                updateRoutine: false
            )
            : nil
        if let failure = WorkoutFinisher.finish(
            workoutID: workout.id,
            in: container.mainContext,
            endedAt: ratedAt,
            summaryCommit: summary,
            effects: finishEffects
        ) {
            throw commandError(failure)
        }
    }

    // MARK: - Resolution

    @MainActor
    private func activeWorkout() -> WorkoutModel? {
        var descriptor = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? container.mainContext.fetch(descriptor).first
    }

    @MainActor
    private func resolveSet(
        expected snapshot: ForgeFitActiveSetSnapshot
    ) throws -> (workout: WorkoutModel, workoutExercise: WorkoutExerciseModel, set: SetModel) {
        guard let workout = activeWorkout(), workout.id == snapshot.workoutID else {
            throw commandError("The active workout changed. I didn't modify a set.")
        }
        guard let workoutExercise = workout.exercises.first(where: { $0.id == snapshot.workoutExerciseID }),
              let set = workoutExercise.sets.first(where: { $0.id == snapshot.setID }) else {
            throw commandError("That set is no longer in the active workout.")
        }
        let currentRevision = revision(for: set)
        guard currentRevision == snapshot.revision else {
            throw commandError("\(snapshot.spokenName) changed while Siri was asking. I didn't overwrite it.")
        }
        return (workout, workoutExercise, set)
    }

    @MainActor
    private func snapshots(in workout: WorkoutModel) -> [ForgeFitActiveSetSnapshot] {
        let context = container.mainContext
        let library = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let exerciseByID = Dictionary(library.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let preferences = WorkoutEffortPolicy.current(defaults: defaults)
        let allSets = workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .flatMap(\.sets)
        let completedCount = allSets.filter { $0.completedAt != nil }.count
        let totalCount = allSets.count

        return orderedSetReferences(in: workout).map { reference in
            let set = reference.set
            let libraryExercise = exerciseByID[reference.workoutExercise.exerciseID]
            let unit = libraryExercise?.preferredWeightUnit ?? globalWeightUnit
            let exerciseName = libraryExercise?.name ?? "Exercise"
            let rpe = preferences.logsEffort
                ? (set.rpe ?? (preferences.defaultsToFailure && set.setType != .warmup ? 10 : nil))
                : nil
            let rir = preferences.logsEffort
                ? (set.rir ?? rpe.map { Int((10 - $0).rounded()) })
                : nil
            return ForgeFitActiveSetSnapshot(
                workoutID: workout.id,
                workoutTitle: workout.title ?? "Workout",
                workoutExerciseID: reference.workoutExercise.id,
                setID: set.id,
                exerciseName: exerciseName,
                setLabel: setLabel(for: set, in: reference.workoutExercise),
                setType: set.setType,
                weightMode: set.weightMode,
                displayUnit: unit,
                reps: set.reps ?? set.prescribedRepTarget?.exactValue,
                loadKilograms: set.modeWeight ?? set.prescribedLoadLowKg,
                rpe: rpe,
                rir: rir,
                partialReps: set.partialReps,
                isCompleted: set.completedAt != nil,
                completedSetCount: completedCount,
                totalSetCount: totalCount,
                logsEffort: preferences.logsEffort,
                defaultsToFailure: preferences.defaultsToFailure,
                needsSpecializedUI: set.setType.isBlockType
                    || set.setType == .amrap
                    || libraryExercise?.isCardio == true,
                revision: revision(for: set)
            )
        }
    }

    private struct OrderedSetReference {
        let workoutExercise: WorkoutExerciseModel
        let set: SetModel
    }

    @MainActor
    private func orderedSetReferences(in workout: WorkoutModel) -> [OrderedSetReference] {
        let visibleExercises: [WorkoutExerciseModel] = OrderedWorkoutItem.ordered(in: workout).compactMap { item -> WorkoutExerciseModel? in
            guard case .exercise(let workoutExercise) = item else { return nil }
            return workoutExercise
        }
        var handledGroups = Set<Int>()
        var result: [OrderedSetReference] = []

        for workoutExercise in visibleExercises {
            guard let group = workoutExercise.supersetGroup else {
                result += workoutExercise.sets
                    .sorted(by: setSort)
                    .map { OrderedSetReference(workoutExercise: workoutExercise, set: $0) }
                continue
            }
            guard handledGroups.insert(group).inserted else { continue }
            let members = visibleExercises
                .filter { $0.supersetGroup == group }
                .sorted(by: exerciseSort)
            let memberSets = members.map { member in
                (member, member.sets.sorted(by: setSort))
            }
            let maximumRoundCount = memberSets.map { pair in
                pair.1.filter { $0.setType != SetType.drop }.count
            }.max() ?? 0

            for round in 0..<maximumRoundCount {
                for (member, sets) in memberSets {
                    for set in sets where SupersetRoundPolicy.logicalRoundIndex(
                        for: set.id,
                        in: sets.map(\.supersetProgress)
                    ) == round {
                        result.append(OrderedSetReference(workoutExercise: member, set: set))
                    }
                }
            }
        }
        return result
    }

    @MainActor
    private func makeFinishPreview(_ workout: WorkoutModel) -> ForgeFitWorkoutFinishPreview {
        let library = (try? container.mainContext.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let names = Dictionary(library.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let summary = IncompleteWorkSummary.make(for: workout, exerciseNames: names)
        let sets = workout.exercises.flatMap(\.sets)
        return ForgeFitWorkoutFinishPreview(
            workoutID: workout.id,
            title: workout.title ?? "Workout",
            completedSetCount: sets.filter { $0.completedAt != nil }.count,
            totalSetCount: sets.count,
            incompleteMessage: summary.message,
            hasSubstance: WorkoutFinisher.hasSubstance(workout),
            revision: ForgeFitWorkoutFinishPreview.Revision(
                workoutUpdatedAt: workout.updatedAt,
                workoutTitle: workout.title,
                workoutNotes: workout.notes,
                exercises: workout.exercises
                    .map {
                        ForgeFitWorkoutFinishPreview.ExerciseState(
                            id: $0.id,
                            updatedAt: $0.updatedAt,
                            exerciseID: $0.exerciseID,
                            position: $0.position,
                            notes: $0.notes,
                            restSeconds: $0.restSeconds,
                            supersetGroup: $0.supersetGroup
                        )
                    }
                    .sorted { $0.id.uuidString < $1.id.uuidString },
                sets: sets
                    .map {
                        ForgeFitWorkoutFinishPreview.SetState(
                            id: $0.id,
                            updatedAt: $0.updatedAt,
                            completedAt: $0.completedAt,
                            setTypeRaw: $0.setTypeRaw,
                            weightModeRaw: $0.weightModeRaw,
                            reps: $0.reps,
                            weight: $0.weight,
                            addedWeight: $0.addedWeight,
                            assistanceWeight: $0.assistanceWeight,
                            rpe: $0.rpe,
                            rir: $0.rir,
                            durationSeconds: $0.durationSeconds,
                            holdSeconds: $0.holdSeconds,
                            partialReps: $0.partialReps,
                            miniRepsJSON: $0.miniRepsJSON,
                            side2Reps: $0.side2Reps,
                            side2MiniRepsJSON: $0.side2MiniRepsJSON
                        )
                    }
                    .sorted { $0.id.uuidString < $1.id.uuidString },
                sessions: workout.cardioSessions
                    .map {
                        ForgeFitWorkoutFinishPreview.SessionState(
                            id: $0.id,
                            updatedAt: $0.updatedAt,
                            liveStartedAt: $0.liveStartedAt,
                            endedAt: $0.endedAt
                        )
                    }
                    .sorted { $0.id.uuidString < $1.id.uuidString },
                blocks: workout.blocks
                    .map {
                        ForgeFitWorkoutFinishPreview.BlockState(
                            id: $0.id,
                            updatedAt: $0.updatedAt,
                            progressJSON: $0.progressJSON,
                            resultJSON: $0.resultJSON
                        )
                    }
                    .sorted { $0.id.uuidString < $1.id.uuidString }
            )
        )
    }

    // MARK: - Mutation support

    @MainActor
    private func startRestIfNeeded(
        after set: SetModel,
        in workoutExercise: WorkoutExerciseModel,
        active workout: WorkoutModel
    ) {
        let sets = workoutExercise.sets.sorted(by: setSort)
        guard !SupersetRoundPolicy.hasPendingDrop(
            after: set.id,
            in: sets.map(\.supersetProgress)
        ) else { return }

        if let group = workoutExercise.supersetGroup {
            guard let round = SupersetRoundPolicy.logicalRoundIndex(
                for: set.id,
                in: sets.map(\.supersetProgress)
            ) else { return }
            let members = workout.exercises
                .filter { $0.supersetGroup == group }
                .sorted(by: exerciseSort)
            guard members.allSatisfy({ member in
                SupersetRoundPolicy.isRoundSatisfied(
                    round,
                    in: member.sets.sorted(by: setSort).map(\.supersetProgress)
                )
            }) else { return }
            startRest(
                after: set,
                in: workoutExercise,
                label: "\(SupersetUI.label(for: group)) rest"
            )
        } else {
            startRest(after: set, in: workoutExercise)
        }
    }

    @MainActor
    private func startRest(
        after set: SetModel,
        in workoutExercise: WorkoutExerciseModel,
        label: String? = nil
    ) {
        let seconds = workoutExercise.restSeconds ?? SetType.working.defaultRestSeconds
        guard let seconds, seconds > 0 else { return }
        RestTimerController.shared.start(
            seconds: seconds,
            label: label ?? setTypeLabel(set.setType)
        )
    }

    @MainActor
    private func publish(workout: WorkoutModel) {
        guard publishesExternalSurfaces else { return }
        WatchLink.shared.configureIfNeeded(container: container)
        // App Intents may run without ContentView and may follow an isolated
        // workout start. The durable path both activates the transport on
        // demand and reads the complete committed graph from a fresh context.
        WatchLink.shared.publishDurableState()
        let library = (try? container.mainContext.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        WorkoutActivityController.shared.update(workout: workout, exercises: library)

        let names = Dictionary(library.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let rows = workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .sorted(by: exerciseSort)
        let allSets = rows.flatMap(\.sets)
        let current = rows.first { row in
            row.sets.contains { $0.completedAt == nil } || row.sets.isEmpty
        } ?? rows.last
        let timer = RestTimerController.shared
        ReadinessSurfacePublisher.publish(ForgeFitWidgetSnapshot(
            mode: .activeWorkout,
            workoutTitle: workout.title ?? "Workout",
            workoutStartedAt: workout.startedAt,
            currentExerciseName: current.flatMap { names[$0.exerciseID] },
            completedSets: allSets.filter { $0.completedAt != nil }.count,
            totalSets: allSets.count,
            restEndsAt: timer.isRunning && !timer.isMicro ? timer.endsAt : nil,
            heartRate: LiveMetricsHub.shared.liveMetrics?.heartRate
        ))
    }

    @MainActor
    private func workoutForRestMutation() throws -> WorkoutModel {
        guard let workout = activeWorkout() else {
            throw commandError("No ForgeFit workout is active.")
        }
        return workout
    }

    @MainActor
    private func needsSpecializedUI(
        set: SetModel,
        workoutExercise: WorkoutExerciseModel
    ) -> Bool {
        guard !set.setType.isBlockType, set.setType != .amrap else { return true }
        let exerciseID = workoutExercise.exerciseID
        var descriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { $0.id == exerciseID && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        return (try? container.mainContext.fetch(descriptor).first)?.isCardio == true
    }

    private func validate(reps: Int) throws {
        guard (0...1000).contains(reps) else {
            throw commandError("Reps must be between 0 and 1,000.")
        }
    }

    private func validateLoad(
        _ kilograms: Double?,
        for mode: WeightMode,
        required: Bool
    ) throws {
        if mode == .bodyweight {
            guard kilograms == nil else {
                throw commandError("Pure bodyweight sets don't have a separate load value.")
            }
            return
        }
        guard let kilograms else {
            if required {
                throw commandError("A load is required before this set can be completed.")
            }
            return
        }
        guard kilograms.isFinite, (0...2000).contains(kilograms) else {
            throw commandError("The load must be between 0 and 2,000 kilograms.")
        }
    }

    private func validateEffort(
        _ values: ForgeFitSetCommandValues,
        preferences: WorkoutEffortPolicy.Preferences
    ) throws {
        if !preferences.logsEffort, values.rpe != nil || values.rir != nil {
            throw commandError("Per-set effort logging is off in ForgeFit Settings, so I didn't save an RPE or RIR.")
        }
        if let rpe = values.rpe, !rpe.isFinite || !(0...10).contains(rpe) {
            throw commandError("RPE must be between 0 and 10.")
        }
        if let rir = values.rir, !(0...10).contains(rir) {
            throw commandError("RIR must be between 0 and 10.")
        }
        if values.rpe != nil, values.rir != nil {
            throw commandError("Give either RPE or RIR for one set, not both.")
        }
    }

    private func applyEffort(_ values: ForgeFitSetCommandValues, to set: SetModel) {
        let preferences = WorkoutEffortPolicy.current(defaults: defaults)
        guard preferences.logsEffort else {
            set.rpe = nil
            set.rir = nil
            return
        }
        if let rpe = values.rpe {
            set.rpe = rpe
            set.rir = nil
        } else if let rir = values.rir {
            set.rpe = 10 - Double(rir)
            set.rir = rir
        } else if preferences.defaultsToFailure, set.setType != .warmup {
            set.rpe = 10
            set.rir = 0
        }
    }

    private var globalWeightUnit: WeightUnit {
        defaults.string(forKey: "weightUnitRaw").flatMap(WeightUnit.init(rawValue:)) ?? .lb
    }

    private func targetText(for snapshot: ForgeFitActiveSetSnapshot) -> String {
        var parts: [String] = []
        parts.append(snapshot.reps.map { "\($0) reps" } ?? "reps not entered")
        switch snapshot.weightMode {
        case .bodyweight:
            parts.append("bodyweight")
        case .bodyweightAdded:
            parts.append(snapshot.loadKilograms.map {
                "bodyweight plus \(loadText($0, unit: snapshot.displayUnit))"
            } ?? "added load not entered")
        case .bodyweightAssisted:
            parts.append(snapshot.loadKilograms.map {
                "\(loadText($0, unit: snapshot.displayUnit)) assistance"
            } ?? "assistance not entered")
        case .external:
            parts.append(snapshot.loadKilograms.map {
                loadText($0, unit: snapshot.displayUnit)
            } ?? "load not entered")
        }
        if snapshot.logsEffort {
            if let rpe = snapshot.rpe {
                parts.append("RPE \(numberText(rpe))")
            } else {
                parts.append("RPE not entered")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func setLabel(for set: SetModel, in workoutExercise: WorkoutExerciseModel) -> String {
        let sets = workoutExercise.sets.sorted(by: setSort)
        let sameTypeOrdinal = (sets.firstIndex { $0.id == set.id }.map { index in
            sets.prefix(index + 1).filter { $0.setType == set.setType }.count
        } ?? 1)
        let workingOrdinal = (sets.firstIndex { $0.id == set.id }.map { index in
            sets.prefix(index + 1).filter { candidate in
                switch candidate.setType {
                case .working, .backoff, .amrap, .lengthenedPartial, .lengthenedExtended: true
                default: false
                }
            }.count
        } ?? 1)

        return switch set.setType {
        case .working: "set \(workingOrdinal)"
        case .warmup: "warm-up set \(sameTypeOrdinal)"
        case .drop: "drop set \(sameTypeOrdinal)"
        case .backoff: "back-off set \(sameTypeOrdinal)"
        case .amrap: "AMRAP set \(sameTypeOrdinal)"
        case .myoRep: "myo-rep set \(sameTypeOrdinal)"
        case .restPause: "rest-pause set \(sameTypeOrdinal)"
        case .cluster: "cluster set \(sameTypeOrdinal)"
        case .lengthenedPartial: "lengthened-partials set \(sameTypeOrdinal)"
        case .lengthenedExtended: "extended set \(sameTypeOrdinal)"
        }
    }

    private func setTypeLabel(_ type: SetType) -> String {
        switch type {
        case .warmup: "Warm-up"
        case .working: "Working"
        case .drop: "Drop set"
        case .restPause: "Rest-pause"
        case .backoff: "Back-off"
        case .amrap: "AMRAP"
        case .myoRep: "Myo-reps"
        case .cluster: "Cluster"
        case .lengthenedPartial: "Lengthened partials"
        case .lengthenedExtended: "Extended set"
        }
    }

    private func revision(for set: SetModel) -> ForgeFitActiveSetSnapshot.Revision {
        ForgeFitActiveSetSnapshot.Revision(
            updatedAt: set.updatedAt,
            completedAt: set.completedAt,
            reps: set.reps,
            loadKilograms: set.modeWeight,
            rpe: set.rpe,
            rir: set.rir,
            partialReps: set.partialReps
        )
    }

    private func hasUnfinishedSessionWork(in workout: WorkoutModel) -> Bool {
        workout.blocks.contains { block in
            !workout.cardioSessions.contains {
                $0.workoutBlockID == block.id && $0.endedAt != nil
            }
        } || workout.cardioSessions.contains { $0.endedAt == nil }
    }

    private func loadText(_ kilograms: Double, unit: WeightUnit) -> String {
        let maximumFractionDigits = unit == .kg ? 2 : 1
        let value = unit.displayValue(fromKilograms: kilograms)
            .formatted(.number.precision(.fractionLength(0...maximumFractionDigits)))
        return "\(value) \(unit.shortSuffix)"
    }

    private func numberText(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return switch (minutes, remainder) {
        case (0, let seconds): "\(seconds) second\(seconds == 1 ? "" : "s")"
        case (let minutes, 0): "\(minutes) minute\(minutes == 1 ? "" : "s")"
        default:
            "\(minutes) minute\(minutes == 1 ? "" : "s") \(remainder) second\(remainder == 1 ? "" : "s")"
        }
    }

    private func commandError(_ message: String) -> ForgeFitActiveWorkoutCommandError {
        ForgeFitActiveWorkoutCommandError(message: message)
    }

    private func setSort(_ lhs: SetModel, _ rhs: SetModel) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func exerciseSort(
        _ lhs: WorkoutExerciseModel,
        _ rhs: WorkoutExerciseModel
    ) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private struct SetMutationState {
        let reps: Int?
        let weight: Double?
        let addedWeight: Double?
        let assistanceWeight: Double?
        let rpe: Double?
        let rir: Int?
        let partialReps: Int?
        let bodyweightKg: Double?
        let effectiveLoad: Double?
        let totalVolume: Double?
        let estimated1RM: Double?
        let completedAt: Date?
        let updatedAt: Date

        init(set: SetModel) {
            reps = set.reps
            weight = set.weight
            addedWeight = set.addedWeight
            assistanceWeight = set.assistanceWeight
            rpe = set.rpe
            rir = set.rir
            partialReps = set.partialReps
            bodyweightKg = set.bodyweightKg
            effectiveLoad = set.effectiveLoad
            totalVolume = set.totalVolume
            estimated1RM = set.estimated1RM
            completedAt = set.completedAt
            updatedAt = set.updatedAt
        }

        func restore(_ set: SetModel) {
            set.reps = reps
            set.weight = weight
            set.addedWeight = addedWeight
            set.assistanceWeight = assistanceWeight
            set.rpe = rpe
            set.rir = rir
            set.partialReps = partialReps
            set.bodyweightKg = bodyweightKg
            set.effectiveLoad = effectiveLoad
            set.totalVolume = totalVolume
            set.estimated1RM = estimated1RM
            set.completedAt = completedAt
            set.updatedAt = updatedAt
        }
    }
}
