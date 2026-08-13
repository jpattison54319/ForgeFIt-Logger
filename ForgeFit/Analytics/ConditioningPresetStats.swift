import ForgeCore
import ForgeData
import Foundation

/// Stable identity for a conditioning prescription. Display names and the
/// generated section/movement IDs are intentionally excluded; changing any
/// work, timing, ordering, load, or scoring field creates a new comparison.
enum ConditioningPrescriptionSignature {
    static func key(for section: ConditioningSection) -> String {
        let movements = section.movements.map { movement in
            [
                movement.exerciseID.uuidString,
                String(movement.targetValue.bitPattern),
                movement.targetUnit.rawValue,
                movement.targetLoad.map { String($0.bitPattern) } ?? "nil",
                movement.weightMode.rawValue
            ].joined(separator: ":")
        }.joined(separator: ";")
        let components: [String] = [
            section.format.rawValue,
            section.ordering.rawValue,
            section.scoreKind.rawValue,
            section.durationSeconds.map(String.init) ?? "nil",
            section.timeCapSeconds.map(String.init) ?? "nil",
            section.rounds.map(String.init) ?? "nil",
            section.intervalSeconds.map(String.init) ?? "nil",
            section.workSeconds.map(String.init) ?? "nil",
            section.restSeconds.map(String.init) ?? "nil",
            section.repScheme.map(String.init).joined(separator: ","),
            section.ladderStep.map(String.init) ?? "nil",
            String(section.endsOnFailure),
            String(section.restartEachInterval),
            movements
        ]
        return components.joined(separator: "|")
    }
}

/// Exact-prescription conditioning history used by built-in presets, custom
/// saved presets, and the performance route from a historical workout.
enum ConditioningPresetStats {
    struct Entry: Identifiable {
        let id: String
        let workout: WorkoutModel
        let section: ConditioningSection
        let result: ConditioningSectionResult

        var date: Date { workout.startedAt }
        var analysis: ConditioningPerformanceAnalysis {
            ConditioningPerformanceAnalysis(section: section, result: result)
        }
        var status: ConditioningSharePresentation.CompletionStatus {
            ConditioningSharePresentation.completionStatus(section: section, result: result)
        }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case performance
        case averageRound
        case fastestRound
        case repRate
        case secondHalfChange
        case completion

        var id: String { rawValue }
    }

    /// Completed and incomplete attempts are retained in the history list.
    /// The primary performance trend below admits completed results only, so a
    /// stopped workout or time-cap never becomes a misleading record.
    static func entries(
        for target: ConditioningSection,
        in workouts: [WorkoutModel]
    ) -> [Entry] {
        let targetKey = ConditioningPrescriptionSignature.key(for: target)
        let targetLineageKey = ConditioningPresetLineageSignature.key(for: target)
        return workouts
            .filter { $0.deletedAt == nil && $0.endedAt != nil }
            .flatMap { workout -> [Entry] in
                contexts(for: workout).flatMap { context in
                    let results = context.result?.sectionResults ?? []
                    return context.plan.sections.enumerated().compactMap { index, section -> Entry? in
                        let sameReference = target.presetReferenceID != nil
                            && section.presetReferenceID == target.presetReferenceID
                        let samePrescription = ConditioningPrescriptionSignature.key(for: section) == targetKey
                        let sameLegacyLineage = ConditioningPresetLineageSignature.key(for: section) == targetLineageKey
                        guard sameReference || samePrescription || sameLegacyLineage else {
                            return nil
                        }
                        let indexedResult = results.indices.contains(index) ? results[index] : nil
                        guard let result = results.first(where: { $0.id == section.id }) ?? indexedResult else {
                            return nil
                        }
                        return Entry(
                            id: "\(workout.id.uuidString)-\(index)-\(section.id.uuidString)",
                            workout: workout,
                            section: section,
                            result: result
                        )
                    }
                }
            }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.id < $1.id
            }
    }

    static func availableMetrics(
        for section: ConditioningSection,
        entries: [Entry]
    ) -> [Metric] {
        Metric.allCases.filter { metric in
            let values = entries.compactMap { value(metric, entry: $0, target: section) }
            guard !values.isEmpty else { return false }
            if metric == .completion {
                // A flat row of completed sessions adds no information.
                return values.contains { $0 < 99.5 }
            }
            return true
        }
    }

    static func series(
        _ metric: Metric,
        for section: ConditioningSection,
        entries: [Entry]
    ) -> [MetricPoint] {
        entries
            .compactMap { entry in
                value(metric, entry: entry, target: section).map {
                    MetricPoint(date: entry.date, value: $0)
                }
            }
            .sorted { $0.date < $1.date }
    }

    static func value(
        _ metric: Metric,
        entry: Entry,
        target: ConditioningSection
    ) -> Double? {
        switch metric {
        case .performance:
            guard entry.result.completed else { return nil }
            switch target.scoreKind {
            case .elapsedTime:
                return positive(entry.result.elapsedSeconds).map(Double.init)
            case .roundsAndReps:
                if target.movements.allSatisfy({ $0.targetUnit == .reps }) {
                    return positive(entry.result.totalReps).map(Double.init)
                }
                return positive(entry.result.fullRounds).map(Double.init)
            case .totalReps:
                return positive(entry.result.totalReps).map(Double.init)
            case .completedIntervals:
                return positive(entry.result.completedIntervals ?? entry.result.fullRounds).map(Double.init)
            case .load:
                guard let load = entry.result.load, load > 0 else { return nil }
                return load
            }
        case .averageRound:
            return entry.analysis.averageRoundSeconds.map(Double.init)
        case .fastestRound:
            return entry.analysis.fastestRoundSeconds.map(Double.init)
        case .repRate:
            return entry.analysis.repsPerMinute
        case .secondHalfChange:
            return entry.analysis.secondHalfPaceChangePercent
        case .completion:
            return entry.analysis.completionPercent
        }
    }

    static func title(_ metric: Metric, for section: ConditioningSection) -> String {
        switch metric {
        case .performance:
            switch section.scoreKind {
            case .elapsedTime: "Finish Time"
            case .roundsAndReps:
                section.movements.allSatisfy({ $0.targetUnit == .reps }) ? "Total Reps" : "Rounds"
            case .totalReps: "Total Reps"
            case .completedIntervals: "Completed Intervals"
            case .load: "Load"
            }
        case .averageRound: "Average Round"
        case .fastestRound: "Fastest Round"
        case .repRate: "Rep Rate"
        case .secondHalfChange: "Second-Half Change"
        case .completion: "Completion"
        }
    }

    static func format(
        _ value: Double,
        metric: Metric,
        section: ConditioningSection,
        unit: WeightUnit = Fmt.unit
    ) -> String {
        switch metric {
        case .performance:
            return switch section.scoreKind {
            case .elapsedTime: Fmt.elapsed(Int(value.rounded()))
            case .roundsAndReps:
                section.movements.allSatisfy({ $0.targetUnit == .reps })
                    ? "\(Int(value.rounded())) reps"
                    : "\(Int(value.rounded())) rounds"
            case .totalReps: "\(Int(value.rounded())) reps"
            case .completedIntervals: "\(Int(value.rounded())) intervals"
            case .load: Fmt.loadUnit(value, unit: unit)
            }
        case .averageRound, .fastestRound:
            return Fmt.elapsed(Int(value.rounded()))
        case .repRate:
            return "\(decimal(value))/min"
        case .secondHalfChange:
            guard abs(value) >= 3 else { return "Even" }
            return "\(decimal(abs(value)))% \(value > 0 ? "slower" : "faster")"
        case .completion:
            return "\(Int(value.rounded()))%"
        }
    }

    /// Units appear once in the axis title. Tick labels stay numeric to keep
    /// dense charts readable.
    static func axisValue(
        _ value: Double,
        metric: Metric,
        section: ConditioningSection,
        unit: WeightUnit = Fmt.unit
    ) -> String {
        switch metric {
        case .performance where section.scoreKind == .elapsedTime,
             .averageRound,
             .fastestRound:
            let seconds = Int(value.rounded())
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .performance where section.scoreKind == .load:
            return Fmt.load(value, unit: unit)
        case .repRate, .secondHalfChange:
            return decimal(value)
        case .performance, .completion:
            return Int(value.rounded()).formatted()
        }
    }

    static func axisLabel(
        _ metric: Metric,
        for section: ConditioningSection,
        unit: WeightUnit = Fmt.unit
    ) -> String {
        switch metric {
        case .performance:
            switch section.scoreKind {
            case .elapsedTime: "Time (min:sec)"
            case .roundsAndReps:
                section.movements.allSatisfy({ $0.targetUnit == .reps }) ? "Total reps" : "Rounds"
            case .totalReps: "Total reps"
            case .completedIntervals: "Intervals"
            case .load: "Load (\(unit.shortSuffix))"
            }
        case .averageRound, .fastestRound: "Time (min:sec)"
        case .repRate: "Rep rate (reps/min)"
        case .secondHalfChange: "Pace change (%)"
        case .completion: "Completion (%)"
        }
    }

    static func interpretation(_ metric: Metric, for section: ConditioningSection) -> String {
        switch metric {
        case .performance:
            let direction = section.scoreKind == .elapsedTime ? "Lower is faster." : "Higher is better."
            return "\(direction) Only completed sessions are compared."
        case .averageRound:
            return "Average elapsed time per completed equal-work round. Lower is faster."
        case .fastestRound:
            return "Fastest measured equal-work round. Only sessions with reliable round checkpoints are included."
        case .repRate:
            return "Completed reps per active minute. Higher means more work at this exact prescription."
        case .secondHalfChange:
            return "Compares the first and second halves of measured round splits. Lower means less slowdown."
        case .completion:
            return "Completed prescribed rounds, including time-capped or unfinished attempts."
        }
    }

    static func bestValue(
        _ metric: Metric,
        for section: ConditioningSection,
        entries: [Entry]
    ) -> Double? {
        let values = entries.compactMap { value(metric, entry: $0, target: section) }
        guard !values.isEmpty else { return nil }
        let lowerIsBetter = metric == .averageRound
            || metric == .fastestRound
            || metric == .secondHalfChange
            || (metric == .performance && section.scoreKind == .elapsedTime)
        return lowerIsBetter ? values.min() : values.max()
    }

    static func sessionScore(_ entry: Entry, unit: WeightUnit = Fmt.unit) -> String {
        switch entry.result.scoreKind {
        case .roundsAndReps:
            if let rounds = entry.result.fullRounds, let reps = entry.result.totalReps {
                return "\(rounds) rounds · \(reps) reps"
            }
            return ConditioningSharePresentation.score(entry.result)
        case .load:
            return Fmt.loadUnit(entry.result.load, unit: unit)
        case .elapsedTime, .totalReps, .completedIntervals:
            return ConditioningSharePresentation.score(entry.result)
        }
    }

    private struct Context {
        let plan: ConditioningPlan
        let result: ConditioningResult?
    }

    private static func contexts(for workout: WorkoutModel) -> [Context] {
        let blocks = workout.blocks
            .filter { $0.kind == .conditioning }
            .sorted { $0.position < $1.position }
            .compactMap { block -> Context? in
                guard let plan = ConditioningPlan.decode(from: block.planSnapshotJSON) else { return nil }
                return Context(plan: plan, result: ConditioningResult.decode(from: block.resultJSON))
            }
        if !blocks.isEmpty { return blocks }
        guard let plan = ConditioningPlan.decode(from: workout.conditioningPlanSnapshotJSON) else { return [] }
        return [Context(plan: plan, result: ConditioningResult.decode(from: workout.conditioningResultJSON))]
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
