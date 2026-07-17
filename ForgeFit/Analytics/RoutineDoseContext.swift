import Foundation
import ForgeCore
import ForgeData

/// Routine-specific context for a green global day. This never changes the
/// daily verdict; it only offers a localized lighter option when the planned
/// dose would compound genuinely high local fatigue.
struct RoutineDoseContext {
    struct Muscle: Identifiable {
        let muscle: String
        let recoveryScore: Double
        let currentWeeklySets: Double
        let plannedSets: Double
        let projectedWeeklySets: Double
        let weeklyThreshold: Double
        let recentAverageRPE: Double?
        let needsLocalizedLighterVersion: Bool

        var id: String { muscle }

        var detail: String {
            let effort = recentAverageRPE.map { " · recent RPE \($0.formatted(.number.precision(.fractionLength(1))))" } ?? ""
            return "\(currentWeeklySets.formatted(.number.precision(.fractionLength(0...1)))) sets this week + \(plannedSets.formatted(.number.precision(.fractionLength(0...1)))) planned\(effort)"
        }
    }

    let muscles: [Muscle]
    let affectedExerciseIDs: Set<UUID>

    var triggeredMuscles: [Muscle] { muscles.filter(\.needsLocalizedLighterVersion) }
    var needsLocalizedLighterVersion: Bool { !triggeredMuscles.isEmpty && !affectedExerciseIDs.isEmpty }

    var affectedMuscleNames: String {
        triggeredMuscles.map { $0.muscle.capitalized }.joined(separator: ", ")
    }

    static func make(
        routine: RoutineModel,
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        recovery: RecoveryEngine.Report,
        calendar: Calendar = .current,
        now: Date = .now
    ) -> RoutineDoseContext {
        let completed = workouts.filter { $0.endedAt != nil && $0.deletedAt == nil }
        let exerciseByID = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let planned = plannedVolume(for: routine, exercises: exerciseByID)
        let current = weeklyVolume(completed, exercises: exerciseByID, start: weekStart(for: now, calendar: calendar), end: now)
        let norm = fourWeekNorm(completed, exercises: exerciseByID, calendar: calendar, now: now)
        let recoveryByMuscle = Dictionary(recovery.recovery.muscles.compactMap { score in
            score.state.value.map { (MuscleTaxonomy.canonical(score.muscle), $0) }
        }, uniquingKeysWith: { first, _ in first })
        let recentEffort = recentAverageRPE(completed, exercises: exerciseByID, calendar: calendar, now: now)

        let muscleContexts = planned.compactMap { muscle, plannedSets -> Muscle? in
            guard let localRecovery = recoveryByMuscle[muscle] else { return nil }
            let currentSets = current[muscle] ?? 0
            let projected = currentSets + plannedSets
            let threshold = norm[muscle].map { $0 * 1.25 } ?? 14
            return Muscle(
                muscle: muscle,
                recoveryScore: localRecovery,
                currentWeeklySets: currentSets,
                plannedSets: plannedSets,
                projectedWeeklySets: projected,
                weeklyThreshold: threshold,
                recentAverageRPE: recentEffort[muscle],
                needsLocalizedLighterVersion: localRecovery < 0.60 && projected > threshold
            )
        }
        .sorted { $0.recoveryScore < $1.recoveryScore }

        let triggeredNames = Set(muscleContexts.filter(\.needsLocalizedLighterVersion).map(\.muscle))
        let affectedExerciseIDs = Set(routine.exercises.compactMap { routineExercise -> UUID? in
            guard let exercise = exerciseByID[routineExercise.exerciseID] else { return nil }
            let loadedMuscles = Set(Set(exercise.primaryMuscles + exercise.secondaryMuscles)
                .map(MuscleTaxonomy.canonical))
            return loadedMuscles.isDisjoint(with: triggeredNames) ? nil : routineExercise.exerciseID
        })

        return RoutineDoseContext(muscles: muscleContexts, affectedExerciseIDs: affectedExerciseIDs)
    }

    private static func plannedVolume(
        for routine: RoutineModel,
        exercises: [UUID: ExerciseLibraryModel]
    ) -> [String: Double] {
        let entries = routine.exercises.flatMap { routineExercise -> [(SetEntry, ExerciseInfo)] in
            guard let exercise = exercises[routineExercise.exerciseID], !exercise.isCardio else { return [] }
            return routineExercise.sets.map { set in
                (
                    SetEntry(
                        id: set.id,
                        setType: set.setType,
                        rpe: set.targetRPE,
                        rir: set.targetRIR,
                        miniSetCount: set.plannedMiniSetCount ?? max(0, set.plannedMiniReps.count - 1)
                    ),
                    exercise.domainInfo
                )
            }
        }
        return MuscleVolume.weeklyVolume(entries)
    }

    private static func weeklyVolume(
        _ workouts: [WorkoutModel],
        exercises: [UUID: ExerciseLibraryModel],
        start: Date,
        end: Date
    ) -> [String: Double] {
        let entries = workouts
            .filter { $0.startedAt >= start && $0.startedAt < end }
            .flatMap { workout in
                workout.exercises.flatMap { workoutExercise -> [(SetEntry, ExerciseInfo)] in
                    guard let exercise = exercises[workoutExercise.exerciseID], !exercise.isCardio else { return [] }
                    return workoutExercise.sets
                        .filter { $0.completedAt != nil }
                        .map { ($0.domainEntry, exercise.domainInfo) }
                }
            }
        return MuscleVolume.weeklyVolume(entries)
    }

    private static func fourWeekNorm(
        _ workouts: [WorkoutModel],
        exercises: [UUID: ExerciseLibraryModel],
        calendar: Calendar,
        now: Date
    ) -> [String: Double] {
        let currentStart = weekStart(for: now, calendar: calendar)
        let starts = (1...4).compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: currentStart) }
        guard starts.count == 4 else { return [:] }
        let weeksWithHistory = starts.filter { start in
            guard let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return false }
            return workouts.contains { $0.startedAt >= start && $0.startedAt < end }
        }
        guard weeksWithHistory.count >= 3 else { return [:] }

        var totals: [String: Double] = [:]
        for start in starts {
            guard let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { continue }
            for (muscle, sets) in weeklyVolume(workouts, exercises: exercises, start: start, end: end) {
                totals[muscle, default: 0] += sets / 4
            }
        }
        return totals
    }

    private static func recentAverageRPE(
        _ workouts: [WorkoutModel],
        exercises: [UUID: ExerciseLibraryModel],
        calendar: Calendar,
        now: Date
    ) -> [String: Double] {
        guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return [:] }
        var total: [String: Double] = [:]
        var count: [String: Int] = [:]
        for workout in workouts where workout.startedAt >= start {
            for workoutExercise in workout.exercises {
                guard let exercise = exercises[workoutExercise.exerciseID], !exercise.isCardio else { continue }
                let rpes = workoutExercise.sets.compactMap(\.rpe)
                guard !rpes.isEmpty else { continue }
                let average = rpes.reduce(0, +) / Double(rpes.count)
                for muscle in Set(exercise.primaryMuscles + exercise.secondaryMuscles).map(MuscleTaxonomy.canonical) {
                    total[muscle, default: 0] += average
                    count[muscle, default: 0] += 1
                }
            }
        }
        var averages: [String: Double] = [:]
        for (muscle, value) in total {
            if let observations = count[muscle], observations > 0 {
                averages[muscle] = value / Double(observations)
            }
        }
        return averages
    }

    private static func weekStart(for date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }
}
