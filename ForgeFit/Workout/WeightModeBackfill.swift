import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Repair for sets created before `WorkoutFactory` stamped weight modes.
///
/// Routine-started workouts materialized every set as `.external`, so sets
/// under a bodyweight-family exercise stored their input in `weight` — and
/// tonnage multiplied that raw number as if it were the lifted load
/// (assistance × reps for assisted work) instead of the effective load
/// (bodyweight − assistance). Two passes:
///
/// - `convertIfNeeded` (one-time): re-stamps each such set with its
///   exercise's mode and moves the value into the mode's field.
/// - `fillMissingBodyweight` (idempotent, cheap): completed bodyweight-family
///   sets that never captured a body mass get the Health sample nearest their
///   completion, so effective load stops resolving to zero. Runs whenever
///   fresh health data lands — it also heals sets completed while no body
///   mass was known yet.
@MainActor
enum WeightModeBackfill {
    private static let convertKey = "weightModeBackfilled.v1"

    static func convertIfNeeded(in context: ModelContext) {
        guard !UserDefaults.standard.bool(forKey: convertKey) else { return }
        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let modeByExerciseID: [UUID: WeightMode] = exercises.reduce(into: [:]) { dict, exercise in
            guard exercise.defaultWeightMode != .external else { return }
            dict[exercise.id] = exercise.defaultWeightMode
        }
        guard !modeByExerciseID.isEmpty else {
            UserDefaults.standard.set(true, forKey: convertKey)
            return
        }
        let workouts = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        for workout in workouts where workout.deletedAt == nil {
            var changed = false
            for workoutExercise in workout.exercises {
                guard let mode = modeByExerciseID[workoutExercise.exerciseID] else { continue }
                for set in workoutExercise.sets where set.weightMode == .external {
                    let value = set.weight
                    set.weightMode = mode
                    // Only move when the mode field is empty — never clobber a
                    // value that somehow already lives where it belongs.
                    if set.modeWeight == nil, let value {
                        set.weight = nil
                        set.setModeWeight(value)
                    }
                    changed = true
                }
            }
            if changed { workout.recomputeTotalVolume() }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: convertKey)
    }

    static func fillMissingBodyweight(
        bodyweightSeries: [(date: Date, value: Double)],
        in context: ModelContext
    ) {
        guard !bodyweightSeries.isEmpty else { return }
        let workouts = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        for workout in workouts where workout.deletedAt == nil {
            var changed = false
            for workoutExercise in workout.exercises {
                for set in workoutExercise.sets
                where set.weightMode != .external && set.completedAt != nil && set.bodyweightKg == nil {
                    let reference = set.completedAt ?? workout.startedAt
                    set.bodyweightKg = nearestBodyweight(to: reference, in: bodyweightSeries)
                    set.recomputeDerivedMetrics()
                    changed = true
                }
            }
            if changed { workout.recomputeTotalVolume() }
        }
        try? context.save()
    }

    private static func nearestBodyweight(
        to date: Date,
        in series: [(date: Date, value: Double)]
    ) -> Double? {
        series.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }?.value
    }
}
