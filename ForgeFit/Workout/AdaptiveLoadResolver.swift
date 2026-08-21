import ForgeCore
import ForgeData
import Foundation

/// A workout-start snapshot of one adaptive routine load. The lower end is
/// the conservative prefill; the full range remains visible and editable.
struct AdaptiveLoadResolution: Equatable {
    let prescription: EstimatedOneRepMaxPrescription
    let baselineKg: Double
    let loadLowKg: Double
    let loadHighKg: Double
}

/// Single source of truth for selecting ForgeFit's existing exercise-scoped
/// estimated-1RM record and turning it into a practical gym load.
@MainActor
enum AdaptiveLoadResolver {
    static func supportsPercentagePrescription(_ exercise: ExerciseLibraryModel?) -> Bool {
        exercise?.modality == .strength && exercise?.defaultWeightMode == .external
    }

    static func bestEstimatedOneRepMax(
        exerciseID: UUID,
        workouts: [WorkoutModel]
    ) -> Double? {
        bestEstimatedOneRepMaxByExercise(workouts: workouts)[exerciseID]
    }

    /// One history pass for list/detail surfaces that render several routine
    /// exercises at once. This avoids rescanning the full log for every row on
    /// each SwiftUI update.
    static func bestEstimatedOneRepMaxByExercise(
        workouts: [WorkoutModel]
    ) -> [UUID: Double] {
        var best: [UUID: Double] = [:]
        for workout in workouts where workout.deletedAt == nil && workout.endedAt != nil {
            for workoutExercise in workout.exercises {
                for set in workoutExercise.sets
                where set.completedAt != nil && set.setType.countsAsWorkingVolume {
                    guard let estimate = set.estimated1RM,
                          estimate.isFinite, estimate > 0 else { continue }
                    best[workoutExercise.exerciseID] = max(
                        best[workoutExercise.exerciseID] ?? 0,
                        estimate
                    )
                }
            }
        }
        return best
    }

    static func resolve(
        _ prescription: EstimatedOneRepMaxPrescription,
        exercise: ExerciseLibraryModel,
        workouts: [WorkoutModel],
        plateInventory: PlateInventory? = nil
    ) -> AdaptiveLoadResolution? {
        guard supportsPercentagePrescription(exercise),
              let baseline = bestEstimatedOneRepMax(exerciseID: exercise.id, workouts: workouts) else {
            return nil
        }
        return resolve(
            prescription,
            exercise: exercise,
            baselineKg: baseline,
            plateInventory: plateInventory
        )
    }

    static func resolve(
        _ prescription: EstimatedOneRepMaxPrescription,
        exercise: ExerciseLibraryModel,
        baselineKg: Double,
        plateInventory: PlateInventory? = nil
    ) -> AdaptiveLoadResolution? {
        guard supportsPercentagePrescription(exercise),
              baselineKg.isFinite, baselineKg > 0,
              let raw = prescription.resolving(estimatedOneRepMaxKg: baselineKg) else { return nil }
        let low = snap(raw.lowKg, for: exercise, plateInventory: plateInventory)
        let high = max(low, snap(raw.highKg, for: exercise, plateInventory: plateInventory))
        return AdaptiveLoadResolution(
            prescription: prescription,
            baselineKg: baselineKg,
            loadLowKg: low,
            loadHighKg: high
        )
    }

    static func snap(
        _ kilograms: Double,
        for exercise: ExerciseLibraryModel,
        plateInventory: PlateInventory? = nil
    ) -> Double {
        guard kilograms.isFinite, kilograms > 0 else { return 0 }
        if ExerciseCatalog.isBarbellLoaded(exercise.equipment) {
            let unit = exercise.effectiveWeightUnit
            let inventory = plateInventory ?? PlateInventoryStore.load(unit: unit)
            return PlateSolution.solve(targetKg: kilograms, inventory: inventory).achievedKg
        }
        let increment = ProgressionPlanner.increment(for: exercise)
        let display = kilograms * increment.displayPerKilogram
        let step = increment.stepDisplay
        let lower = floor(display / step) * step
        let upper = ceil(display / step) * step
        let snappedDisplay = display - lower <= upper - display ? lower : upper
        return max(step, snappedDisplay) / increment.displayPerKilogram
    }
}
