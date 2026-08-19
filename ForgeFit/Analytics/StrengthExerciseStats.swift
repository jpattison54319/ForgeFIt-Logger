import Foundation
import ForgeCore
import ForgeData

/// Exercise-scoped strength trends derived from completed working sets. Each
/// point is one performed session, so changing the selected metric never mixes
/// set-level points with session-level totals.
nonisolated enum StrengthExerciseStats {
    enum Metric: String, CaseIterable, Identifiable {
        case estimatedOneRepMax = "Estimated 1RM"
        case bestWeight = "Best Weight"
        case sessionVolume = "Session Volume"
        case workingSets = "Working Sets"

        var id: String { rawValue }

        @MainActor
        func format(_ value: Double, unit: WeightUnit) -> String {
            switch self {
            case .estimatedOneRepMax, .bestWeight:
                Fmt.loadUnit(value, unit: unit)
            case .sessionVolume:
                Fmt.volume(value, unit: unit)
            case .workingSets:
                Fmt.sets(value)
            }
        }

        @MainActor
        func axisValue(_ value: Double, unit: WeightUnit) -> String {
            switch self {
            case .estimatedOneRepMax, .bestWeight, .sessionVolume:
                unit.displayValue(fromKilograms: value)
                    .formatted(.number.precision(.fractionLength(0...1)))
            case .workingSets:
                value.formatted(.number.precision(.fractionLength(0...1)))
            }
        }

        @MainActor
        func axisLabel(unit: WeightUnit) -> String {
            switch self {
            case .estimatedOneRepMax, .bestWeight:
                "Load (\(unit.shortSuffix))"
            case .sessionVolume:
                "Volume (\(unit.shortSuffix))"
            case .workingSets:
                "Sets"
            }
        }

        var interpretation: String {
            switch self {
            case .estimatedOneRepMax:
                "Best estimated one-rep max from completed working sets in each session."
            case .bestWeight:
                "Heaviest effective load completed in each session."
            case .sessionVolume:
                "Total load across completed working sets in each session."
            case .workingSets:
                "Effective working sets, including the app's fractional counts for structured set types."
            }
        }
    }

    static func availableMetrics(exerciseID: UUID, workouts: [WorkoutModel]) -> [Metric] {
        Metric.allCases.filter { !series($0, exerciseID: exerciseID, workouts: workouts).isEmpty }
    }

    /// One point per workout, oldest first. Warmups, pending sets, deleted
    /// workouts, and workouts without this exercise do not enter the series.
    static func series(
        _ metric: Metric,
        exerciseID: UUID,
        workouts: [WorkoutModel]
    ) -> [MetricPoint] {
        workouts
            .filter { $0.deletedAt == nil && $0.endedAt != nil }
            .compactMap { workout -> MetricPoint? in
                let sets = workout.exercises
                    .filter { $0.exerciseID == exerciseID }
                    .flatMap(\.sets)
                    .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
                guard !sets.isEmpty else { return nil }

                let value: Double? = switch metric {
                case .estimatedOneRepMax:
                    sets.compactMap(\.estimated1RM).filter { $0 > 0 }.max()
                case .bestWeight:
                    sets.compactMap(\.effectiveLoad).filter { $0 > 0 }.max()
                case .sessionVolume:
                    sets.compactMap(\.totalVolume).filter { $0 > 0 }.reduce(0, +).nonzero
                case .workingSets:
                    sets.reduce(0) { $0 + VolumeMath.effectiveSetCount($1.domainEntry) }.nonzero
                }
                return value.map { MetricPoint(date: workout.startedAt, value: $0) }
            }
            .sorted { $0.date < $1.date }
    }
}

private extension Double {
    nonisolated var nonzero: Double? { self > 0 ? self : nil }
}
