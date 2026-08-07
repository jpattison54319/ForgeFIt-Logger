import ForgeCore
import ForgeData
import Foundation

enum ExperimentAnalysisAdapterError: LocalizedError, Equatable {
    case futureReferenceWindow

    var errorDescription: String? {
        switch self {
        case .futureReferenceWindow:
            "Comparison periods cannot include future time."
        }
    }
}

enum ExperimentReferenceSelection: Equatable, Hashable, Codable {
    case previousEqualPeriod
    case experiment(id: UUID, start: Date, end: Date, timeZoneIdentifier: String)
    case custom(start: Date, end: Date, timeZoneIdentifier: String)
}

/// Bridges main-actor SwiftData/Health objects to ForgeCore's Sendable exact-
/// window engine. All comparison math, duration normalization, zero-baseline
/// handling, and coverage remain owned by ForgeCore.
@MainActor
enum ExperimentAnalysisAdapter {
    static func result(
        experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        entries: [ExperimentEntryModel],
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        reference: ExperimentReferenceSelection = .previousEqualPeriod,
        customTrackerPairs: [UUID: UUID] = [:],
        healthSnapshot: ExperimentHealthSnapshot? = nil,
        now: Date = .now
    ) throws -> ExperimentResult {
        let request = try comparisonRequest(
            experiment: experiment,
            reference: reference,
            now: now
        )
        let headline = ExperimentUIStore.headlineSelections(for: experiment)
        let automatic = ExperimentHeadlineMetricOption.all.map(\.selection)
        let detailed = detailedSelections(workouts: workouts, request: request)
        let custom = customSelections(
            trackers,
            experimentID: experiment.id
        )
        // Headline choices control prominence, not capture. The full supported
        // automatic catalog remains available in the category sections.
        let selections = deduplicated(headline + automatic + detailed + custom)
        let observations = observations(
            selections: selections,
            entries: entries,
            workouts: workouts,
            exercises: exercises,
            request: request,
            currentExperimentID: experiment.id,
            trackers: trackers,
            customTrackerPairs: customTrackerPairs,
            healthSnapshot: healthSnapshot ?? .empty
        )
        return try ExperimentComparisonEngine.evaluate(
            request: request,
            selections: selections,
            observations: observations
        )
    }

    static func comparisonRequest(
        experiment: ExperimentModel,
        reference: ExperimentReferenceSelection,
        now: Date = .now
    ) throws -> ExperimentComparisonRequest {
        let terminalEnd = experiment.endedAt ?? experiment.plannedEndAt
        let planned = try ExperimentWindow(
            start: experiment.startedAt,
            end: terminalEnd,
            timeZoneIdentifier: experiment.timeZoneIdentifier
        )
        let current: ExperimentWindow
        if experiment.isActive {
            current = try ExperimentComparisonEngine.activeElapsedRequest(
                for: planned,
                now: now
            ).currentWindow
        } else {
            current = planned
        }

        switch reference {
        case .previousEqualPeriod:
            break
        case let .experiment(_, _, end, _), let .custom(_, end, _):
            guard end <= now else {
                throw ExperimentAnalysisAdapterError.futureReferenceWindow
            }
        }

        let coreReference: ExperimentComparisonReference = switch reference {
        case .previousEqualPeriod:
            .previousEqualPeriod
        case let .experiment(id, start, end, timeZoneIdentifier):
            .experiment(
                id: id,
                window: try ExperimentWindow(
                    start: start,
                    end: end,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            )
        case let .custom(start, end, timeZoneIdentifier):
            .custom(
                window: try ExperimentWindow(
                    start: start,
                    end: end,
                    timeZoneIdentifier: timeZoneIdentifier
                )
            )
        }
        return ExperimentComparisonRequest(
            currentWindow: current,
            reference: coreReference
        )
    }

    private static func customSelections(
        _ trackers: [ExperimentTrackerModel],
        experimentID: UUID
    ) -> [ExperimentMetricSelection] {
        trackers.compactMap { tracker in
            guard tracker.experimentID == experimentID,
                  tracker.deletedAt == nil else { return nil }
            let valueKind: InsightValueKind
            switch tracker.type {
            case .number: valueKind = .score
            case .boolean: valueKind = .percentage
            case .rating: valueKind = .score
            case .choice, .note: return nil
            }
            return ExperimentMetricSelection(
                metricID: "custom.tracker",
                scope: ExperimentMetricScope(
                    kind: .tracker,
                    id: tracker.id.uuidString
                ),
                valueKind: valueKind,
                aggregation: .mean
            )
        }
    }

    /// Cross-experiment custom values are comparable only when their stored
    /// scalar meanings agree. Number trackers additionally require the same
    /// normalized user-defined unit so the adapter never calculates a delta
    /// between unlike quantities.
    static func customTrackersAreComparable(
        _ current: ExperimentTrackerModel,
        _ reference: ExperimentTrackerModel
    ) -> Bool {
        guard current.deletedAt == nil,
              reference.deletedAt == nil,
              current.type == reference.type else {
            return false
        }
        switch current.type {
        case .number:
            return normalizedUnit(current.unit) == normalizedUnit(reference.unit)
        case .boolean, .rating:
            return true
        case .choice, .note:
            return false
        }
    }

    private static func detailedSelections(
        workouts: [WorkoutModel],
        request: ExperimentComparisonRequest
    ) -> [ExperimentMetricSelection] {
        guard let reference = try? ExperimentComparisonEngine.resolvedReferenceWindow(for: request) else {
            return []
        }
        let relevant = workouts.filter {
            $0.deletedAt == nil
                && $0.endedAt != nil
                && (request.currentWindow.contains($0.startedAt)
                    || reference.contains($0.startedAt))
        }
        let exerciseIDs = Set(relevant.flatMap { workout in
            workout.exercises.compactMap { row -> UUID? in
                row.sets.contains {
                    $0.completedAt != nil && $0.setType.countsAsWorkingVolume
                } ? row.exerciseID : nil
            }
        })
        let modalities = Set(relevant.flatMap { workout in
            workout.cardioSessions.compactMap { session -> String? in
                guard session.deletedAt == nil,
                      session.endedAt != nil,
                      !session.isYogaSession else {
                    return nil
                }
                return normalizedModality(session.modality)
            }
        })

        let strength = exerciseIDs.sorted { $0.uuidString < $1.uuidString }.flatMap { id in
            ExperimentDetailedMetric.strength.map {
                $0.selection(scopeID: id.uuidString)
            }
        }
        let cardio = modalities.sorted().flatMap { modality in
            ExperimentDetailedMetric.cardio.map {
                $0.selection(scopeID: modality)
            }
        }
        return strength + cardio
    }

    private static func deduplicated(
        _ selections: [ExperimentMetricSelection]
    ) -> [ExperimentMetricSelection] {
        var seen = Set<ExperimentMetricKey>()
        return selections.filter { seen.insert($0.key).inserted }
    }

    private static func observations(
        selections: [ExperimentMetricSelection],
        entries: [ExperimentEntryModel],
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        request: ExperimentComparisonRequest,
        currentExperimentID: UUID,
        trackers: [ExperimentTrackerModel],
        customTrackerPairs: [UUID: UUID],
        healthSnapshot: ExperimentHealthSnapshot
    ) -> [ExperimentMetricObservation] {
        var byID: [String: ExperimentMetricSelection] = [:]
        for selection in selections where byID[selection.metricID] == nil {
            byID[selection.metricID] = selection
        }
        let byKey = Dictionary(
            selections.map { ($0.key, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let referenceWindow = try? ExperimentComparisonEngine.resolvedReferenceWindow(
            for: request
        )
        let completed = workouts.filter {
            $0.deletedAt == nil
                && $0.endedAt != nil
                && (request.currentWindow.contains($0.startedAt)
                    || referenceWindow?.contains($0.startedAt) == true)
        }
        let analytics = TrainingAnalytics(workouts: completed, exercises: exercises)
        var rows: [ExperimentMetricObservation] = []

        for workout in completed {
            let summary = analytics.summary(for: workout)
            let workingSets = workout.exercises
                .flatMap(\.sets)
                .filter {
                    $0.completedAt != nil
                        && $0.setType.countsAsWorkingVolume
                }
            let provenance: InsightProvenance = workout.sourceDevice?.hasPrefix("healthkit") == true
                || workout.externalSource != nil ? .imported : .measured
            if let selection = byID["strength.volume"] {
                // One row per attempted working set keeps an unknown load
                // visible as missing coverage. TrainingAnalytics' workout
                // summary intentionally uses zero for other dashboard totals,
                // which is not an honest experiment observation.
                for set in workingSets {
                    rows.append(.init(
                        metric: selection.key,
                        timestamp: workout.startedAt,
                        value: optionalTotalVolume(for: set),
                        provenance: provenance
                    ))
                }
            }
            if let selection = byID["strength.workingSets"], summary.hasStrength {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: workout.startedAt,
                    value: summary.sets,
                    provenance: provenance
                ))
            }
            if let selection = byID["strength.reps"] {
                for set in workingSets {
                    rows.append(.init(
                        metric: selection.key,
                        timestamp: workout.startedAt,
                        value: set.reps.map(Double.init),
                        provenance: provenance
                    ))
                }
            }

            for exerciseRow in workout.exercises {
                let completedSets = exerciseRow.sets.filter { $0.completedAt != nil }
                let workingSets = completedSets.filter { $0.setType.countsAsWorkingVolume }
                guard !workingSets.isEmpty else { continue }
                let scope = ExperimentMetricScope(
                    kind: .exercise,
                    id: exerciseRow.exerciseID.uuidString
                )

                if let selection = byKey[.init(
                    metricID: ExperimentDetailedMetric.exerciseVolume.rawValue,
                    scope: scope
                )] {
                    for set in workingSets {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: optionalTotalVolume(for: set),
                            provenance: provenance
                        ))
                    }
                }
                if let selection = byKey[.init(
                    metricID: ExperimentDetailedMetric.exerciseWorkingSets.rawValue,
                    scope: scope
                )] {
                    rows.append(.init(
                        metric: selection.key,
                        timestamp: workout.startedAt,
                        value: workingSets.reduce(0) {
                            $0 + VolumeMath.effectiveSetCount($1.domainEntry)
                        },
                        provenance: provenance
                    ))
                }
                if let selection = byKey[.init(
                    metricID: ExperimentDetailedMetric.exerciseBestLoad.rawValue,
                    scope: scope
                )] {
                    for set in workingSets {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: optionalEffectiveLoad(for: set),
                            provenance: provenance
                        ))
                    }
                }
                if let selection = byKey[.init(
                    metricID: ExperimentDetailedMetric.exerciseBestEstimated1RM.rawValue,
                    scope: scope
                )] {
                    for set in workingSets {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: optionalEstimatedOneRepMax(for: set),
                            provenance: .estimated
                        ))
                    }
                }
            }

            for session in workout.cardioSessions
                where session.deletedAt == nil && session.endedAt != nil {
                let sessionProvenance: InsightProvenance =
                    session.sourceDevice?.hasPrefix("healthkit") == true ? .imported : provenance
                if session.isYogaSession {
                    if let selection = byID["yoga.duration"] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.durationSeconds.map(Double.init),
                            provenance: sessionProvenance
                        ))
                    }
                } else {
                    if let selection = byID["cardio.duration"] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.durationSeconds.map(Double.init),
                            provenance: sessionProvenance,
                            group: normalizedModality(session.modality)
                        ))
                    }
                    if let selection = byID["cardio.distance"] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.distanceMeters,
                            provenance: sessionProvenance,
                            group: normalizedModality(session.modality)
                        ))
                    }

                    let modality = normalizedModality(session.modality)
                    let scope = ExperimentMetricScope(kind: .modality, id: modality)
                    let durationWeight = Double(session.durationSeconds ?? 0)
                    let group = modality

                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioSessions.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: 1,
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioDuration.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.durationSeconds.map(Double.init),
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioDistance.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.distanceMeters,
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioPace.rawValue,
                        scope: scope
                    )] {
                        let pace: Double?
                        if let meters = session.distanceMeters,
                           meters > 100,
                           let duration = session.durationSeconds,
                           duration > 0 {
                            pace = Double(duration) / meters
                        } else {
                            pace = nil
                        }
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: pace,
                            provenance: sessionProvenance,
                            group: group,
                            weight: session.distanceMeters ?? 0
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioAverageHeartRate.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.avgHR.map(Double.init),
                            provenance: sessionProvenance,
                            group: group,
                            weight: durationWeight
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioMaximumHeartRate.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.maxHR.map(Double.init),
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioHighZoneTime.rawValue,
                        scope: scope
                    )] {
                        let seconds = session.hrZoneSeconds.count >= 5
                            ? Double(session.hrZoneSeconds[3] + session.hrZoneSeconds[4])
                            : nil
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: seconds,
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioActiveEnergy.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.activeEnergyKcal,
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioPower.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.avgPowerWatts,
                            provenance: sessionProvenance,
                            group: group,
                            weight: durationWeight
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioElevation.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.elevationGainMeters,
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                    if let selection = byKey[.init(
                        metricID: ExperimentDetailedMetric.cardioSteps.rawValue,
                        scope: scope
                    )] {
                        rows.append(.init(
                            metric: selection.key,
                            timestamp: workout.startedAt,
                            value: session.totalSteps.map(Double.init),
                            provenance: sessionProvenance,
                            group: group
                        ))
                    }
                }
            }
        }

        rows.append(contentsOf: exerciseFrequencyObservations(
            workouts: completed,
            selectionsByKey: byKey,
            request: request
        ))

        rows.append(contentsOf: customTrackerObservations(
            selections: selections,
            trackers: trackers,
            entries: entries,
            currentExperimentID: currentExperimentID,
            request: request,
            customTrackerPairs: customTrackerPairs
        ))

        rows.append(contentsOf: healthObservations(
            selectionsByID: byID,
            request: request,
            snapshot: healthSnapshot
        ))
        return rows
    }

    /// `SetModel` intentionally stores zero-valued derived metrics when a
    /// required load component is absent. That is useful to keep dashboard
    /// totals additive, but an experiment must distinguish a real zero from
    /// an unmeasured load so its coverage and comparison are truthful.
    static func optionalEffectiveLoad(for set: SetModel) -> Double? {
        switch set.weightMode {
        case .external:
            return set.isUnilateral ? set.implementWeight : set.weight
        case .bodyweight:
            return set.bodyweightKg
        case .bodyweightAdded:
            guard let bodyweight = set.bodyweightKg,
                  let addedWeight = set.addedWeight else {
                return nil
            }
            return bodyweight + addedWeight
        case .bodyweightAssisted:
            guard let bodyweight = set.bodyweightKg,
                  let assistance = set.assistanceWeight else {
                return nil
            }
            return max(0, bodyweight - assistance)
        }
    }

    static func optionalTotalVolume(for set: SetModel) -> Double? {
        guard set.setType.countsAsWorkingVolume,
              let load = optionalEffectiveLoad(for: set),
              set.reps != nil || set.partialReps != nil else {
            return nil
        }

        let fullReps = Double(set.reps ?? 0)
        let partialReps = Double(set.partialReps ?? 0) * 0.5
        let limbs = set.isUnilateral ? Double(max(1, set.limbCount)) : 1
        var volume = load * (fullReps + partialReps) * limbs

        if set.hasSide2Data {
            if set.isUnilateral, set.limbCount > 1 {
                volume /= Double(set.limbCount)
            }
            let sideTwoReps = (set.side2Reps ?? 0) + set.side2MiniReps.reduce(0, +)
            volume += load * Double(sideTwoReps)
        }

        if set.setType == .myoRep || set.setType == .restPause {
            volume += load * Double(set.miniReps.reduce(0, +))
        }
        return volume
    }

    /// Stored derived 1RM values use the app-wide additive load convention.
    /// Experiments first require every load component so an incomplete
    /// bodyweight set remains missing rather than becoming a zero-load
    /// estimate.
    static func optionalEstimatedOneRepMax(for set: SetModel) -> Double? {
        guard optionalEffectiveLoad(for: set) != nil else { return nil }
        return set.estimated1RM
    }

    private static func exerciseFrequencyObservations(
        workouts: [WorkoutModel],
        selectionsByKey: [ExperimentMetricKey: ExperimentMetricSelection],
        request: ExperimentComparisonRequest
    ) -> [ExperimentMetricObservation] {
        guard let reference = try? ExperimentComparisonEngine.resolvedReferenceWindow(for: request) else {
            return []
        }
        var observations: [ExperimentMetricObservation] = []

        for window in [request.currentWindow, reference] {
            var seenDaysByExercise: [UUID: Set<Date>] = [:]
            for workout in workouts.sorted(by: { $0.startedAt < $1.startedAt })
                where window.contains(workout.startedAt) {
                let exerciseIDs = Set(workout.exercises.compactMap { row -> UUID? in
                    row.sets.contains {
                        $0.completedAt != nil && $0.setType.countsAsWorkingVolume
                    } ? row.exerciseID : nil
                })
                let day = window.calendar.startOfDay(for: workout.startedAt)
                let provenance: InsightProvenance =
                    workout.sourceDevice?.hasPrefix("healthkit") == true
                    || workout.externalSource != nil ? .imported : .measured

                for exerciseID in exerciseIDs {
                    var seenDays = seenDaysByExercise[exerciseID] ?? []
                    guard seenDays.insert(day).inserted else { continue }
                    seenDaysByExercise[exerciseID] = seenDays
                    let scope = ExperimentMetricScope(
                        kind: .exercise,
                        id: exerciseID.uuidString
                    )
                    guard let selection = selectionsByKey[.init(
                        metricID: ExperimentDetailedMetric.exerciseFrequency.rawValue,
                        scope: scope
                    )] else { continue }
                    observations.append(.init(
                        metric: selection.key,
                        timestamp: workout.startedAt,
                        value: 1,
                        provenance: provenance
                    ))
                }
            }
        }
        return observations
    }

    private static func normalizedModality(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CardioKind.other.rawValue }
        if let exact = CardioKind(rawValue: trimmed) {
            return exact.rawValue
        }
        let inferred = CardioKind.infer(name: trimmed, equipment: nil)
        if inferred != .other
            || trimmed.caseInsensitiveCompare(CardioKind.other.rawValue) == .orderedSame {
            return inferred.rawValue
        }
        return trimmed
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func customTrackerObservations(
        selections: [ExperimentMetricSelection],
        trackers: [ExperimentTrackerModel],
        entries: [ExperimentEntryModel],
        currentExperimentID: UUID,
        request: ExperimentComparisonRequest,
        customTrackerPairs: [UUID: UUID]
    ) -> [ExperimentMetricObservation] {
        let trackerSelectionPairs: [(UUID, ExperimentMetricSelection)] = selections.compactMap {
            selection -> (UUID, ExperimentMetricSelection)? in
            guard selection.metricID == "custom.tracker",
                  selection.scope?.kind == .tracker,
                  let raw = selection.scope?.id,
                  let id = UUID(uuidString: raw) else { return nil }
            return (id, selection)
        }
        let trackerSelections = Dictionary(uniqueKeysWithValues: trackerSelectionPairs)
        let currentTrackers: [UUID: ExperimentTrackerModel] = Dictionary(
            uniqueKeysWithValues: trackers.compactMap {
                tracker -> (UUID, ExperimentTrackerModel)? in
                guard tracker.experimentID == currentExperimentID,
                      tracker.deletedAt == nil,
                      trackerSelections[tracker.id] != nil else {
                    return nil
                }
                return (tracker.id, tracker)
            }
        )

        var rows: [ExperimentMetricObservation] = []
        for entry in entries where entry.deletedAt == nil
            && entry.experimentID == currentExperimentID {
            guard let tracker = currentTrackers[entry.trackerID],
                  let selection = trackerSelections[tracker.id] else {
                continue
            }
            rows.append(.init(
                metric: selection.key,
                timestamp: entry.observedAt,
                value: numericValue(entry.value, expectedType: tracker.type),
                provenance: .measured
            ))
        }

        guard case let .experiment(referenceExperimentID, _) = request.reference else {
            // Previous-period and custom-range comparisons intentionally
            // retain the same tracker UUID on both sides.
            return rows
        }

        let referenceTrackers: [UUID: ExperimentTrackerModel] = Dictionary(
            uniqueKeysWithValues: trackers.compactMap {
                tracker -> (UUID, ExperimentTrackerModel)? in
                guard tracker.experimentID == referenceExperimentID,
                      tracker.deletedAt == nil else {
                    return nil
                }
                return (tracker.id, tracker)
            }
        )
        var mappingsByReferenceID:
            [UUID: [(tracker: ExperimentTrackerModel, selection: ExperimentMetricSelection)]] = [:]
        for (currentTrackerID, referenceTrackerID) in customTrackerPairs {
            guard let currentTracker = currentTrackers[currentTrackerID],
                  let referenceTracker = referenceTrackers[referenceTrackerID],
                  let selection = trackerSelections[currentTrackerID],
                  customTrackersAreComparable(currentTracker, referenceTracker) else {
                continue
            }
            mappingsByReferenceID[referenceTrackerID, default: []].append(
                (referenceTracker, selection)
            )
        }

        for entry in entries where entry.deletedAt == nil
            && entry.experimentID == referenceExperimentID {
            guard let mappings = mappingsByReferenceID[entry.trackerID] else {
                continue
            }
            for mapping in mappings {
                rows.append(.init(
                    // Reference observations deliberately reuse the current
                    // selection key; explicit pairing is the only bridge
                    // between the two independent tracker UUIDs.
                    metric: mapping.selection.key,
                    timestamp: entry.observedAt,
                    value: numericValue(
                        entry.value,
                        expectedType: mapping.tracker.type
                    ),
                    provenance: .measured
                ))
            }
        }
        return rows
    }

    private static func numericValue(
        _ value: ExperimentEntryValue?,
        expectedType: ExperimentTrackerType
    ) -> Double? {
        switch (expectedType, value) {
        case let (.number, .number(value)): value.isFinite ? value : nil
        case let (.boolean, .boolean(value)): value ? 100 : 0
        case let (.rating, .rating(value)):
            (1...5).contains(value) ? Double(value) : nil
        default: nil
        }
    }

    private static func normalizedUnit(_ unit: String?) -> String {
        unit?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func healthObservations(
        selectionsByID: [String: ExperimentMetricSelection],
        request: ExperimentComparisonRequest,
        snapshot: ExperimentHealthSnapshot
    ) -> [ExperimentMetricObservation] {
        guard selectionsByID.keys.contains(where: { $0.hasPrefix("health.") }) else { return [] }
        guard let reference = try? ExperimentComparisonEngine.resolvedReferenceWindow(for: request) else {
            return []
        }
        var rows: [ExperimentMetricObservation] = []
        for day in snapshot.days
            where request.currentWindow.contains(day.timestamp)
                || reference.contains(day.timestamp) {
            let timestamp = day.timestamp
            if let selection = selectionsByID["health.sleepTotal"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.sleepTotalMinutes.map { Double($0) * 60 },
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.sleepDeep"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.sleepDeepMinutes.map { Double($0) * 60 },
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.sleepREM"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.sleepREMMinutes.map { Double($0) * 60 },
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.hrv"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.hrvMilliseconds,
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.restingHR"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.restingHeartRate.map(Double.init),
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.respiratoryRate"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.respiratoryRate,
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.oxygenSaturation"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.oxygenSaturationPercent,
                    provenance: day.provenance
                ))
            }
            if let selection = selectionsByID["health.steps"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.steps
                ))
            }
            if let selection = selectionsByID["health.exerciseMinutes"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.exerciseMinutes.map { $0 * 60 }
                ))
            }
            if let selection = selectionsByID["health.activeEnergy"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.activeEnergyKilocalories
                ))
            }
            if let selection = selectionsByID["health.bodyweight"] {
                rows.append(.init(
                    metric: selection.key,
                    timestamp: timestamp,
                    value: day.bodyWeightKilograms
                ))
            }
        }
        return rows
    }
}
