import ForgeCore
import ForgeData
import Foundation

// MARK: - Record kinds

/// A per-set achievement relative to the user's full history for one exercise.
enum RecordKind: String, CaseIterable {
    case heaviestWeight
    case bestSetVolume
    case best1RM

    var label: String {
        switch self {
        case .heaviestWeight: "Heaviest weight"
        case .bestSetVolume: "Best set volume"
        case .best1RM: "Best est. 1RM"
        }
    }

    var icon: String {
        switch self {
        case .heaviestWeight: "scalemass.fill"
        case .bestSetVolume: "chart.bar.fill"
        case .best1RM: "bolt.fill"
        }
    }

    /// The record-setting value on `set`, formatted in the exercise's unit.
    func valueText(for set: SetModel, unit: WeightUnit) -> String {
        switch self {
        case .heaviestWeight: Fmt.loadUnit(set.effectiveLoad, unit: unit)
        case .bestSetVolume: Fmt.volumeFull(set.totalVolume, unit: unit)
        case .best1RM: Fmt.loadUnit(set.estimated1RM, unit: unit)
        }
    }
}

// MARK: - Baseline

/// The best prior values for one exercise — the bar a set must clear to earn
/// an award.
struct ExerciseRecordBaseline {
    var maxLoad: Double = 0
    var maxSetVolume: Double = 0
    var max1RM: Double = 0
    /// Awards require prior logged history for the exercise — otherwise every
    /// set of a first session would be a "record" and the signal means nothing.
    var hasHistory: Bool = false

    mutating func absorb(_ set: SetModel) {
        guard set.completedAt != nil, set.setType.countsAsWorkingVolume else { return }
        if let load = set.effectiveLoad, load > 0 {
            maxLoad = max(maxLoad, load)
            hasHistory = true
        }
        if let volume = set.totalVolume, volume > 0 { maxSetVolume = max(maxSetVolume, volume) }
        if let oneRM = set.estimated1RM, oneRM > 0 { max1RM = max(max1RM, oneRM) }
    }
}

// MARK: - Engine

/// Derives records on the fly (never persisted), so the live logger, the
/// post-workout summary, and any future surface all agree by construction.
enum PersonalRecords {

    /// Best prior values per exercise from workouts finished before `workout`
    /// started. The date cut-off keeps historical edits honest: editing an old
    /// workout only compares against what existed at the time.
    static func baselines(history: [WorkoutModel], before workout: WorkoutModel) -> [UUID: ExerciseRecordBaseline] {
        var result: [UUID: ExerciseRecordBaseline] = [:]
        let prior = history.filter {
            $0.id != workout.id && $0.endedAt != nil && $0.deletedAt == nil && $0.startedAt < workout.startedAt
        }
        for past in prior {
            for we in past.exercises {
                var baseline = result[we.exerciseID] ?? ExerciseRecordBaseline()
                for set in we.sets { baseline.absorb(set) }
                result[we.exerciseID] = baseline
            }
        }
        return result
    }

    /// Awards for one completed set, judged against history plus every set of
    /// the same exercise completed earlier in this session — so a later set
    /// must beat an earlier award to earn its own.
    static func awards(for set: SetModel, baseline: ExerciseRecordBaseline?, sessionSets: [SetModel]) -> [RecordKind] {
        guard let baseline, baseline.hasHistory,
              let completedAt = set.completedAt,
              set.setType.countsAsWorkingVolume else { return [] }

        var bar = baseline
        for other in sessionSets where other.id != set.id {
            if let otherDone = other.completedAt, otherDone < completedAt {
                bar.absorb(other)
            }
        }

        var kinds: [RecordKind] = []
        if let load = set.effectiveLoad, load > 0, load > bar.maxLoad { kinds.append(.heaviestWeight) }
        if let volume = set.totalVolume, volume > 0, volume > bar.maxSetVolume { kinds.append(.bestSetVolume) }
        if let oneRM = set.estimated1RM, oneRM > 0, oneRM > bar.max1RM { kinds.append(.best1RM) }
        return kinds
    }

    /// An all-time record for one exercise: the best set ever logged for a
    /// kind, with the date it happened.
    struct AllTimeBest: Identifiable {
        let kind: RecordKind
        let set: SetModel
        let date: Date
        var id: String { kind.rawValue }
    }

    /// The user's standing records for one exercise across every workout,
    /// including a still-active session (a record is a record the moment the
    /// set is checked off).
    static func allTimeBests(for exerciseID: UUID, in workouts: [WorkoutModel]) -> [AllTimeBest] {
        var candidates: [(set: SetModel, date: Date)] = []
        for workout in workouts where workout.deletedAt == nil {
            for we in workout.exercises where we.exerciseID == exerciseID {
                for set in we.sets where set.completedAt != nil && set.setType.countsAsWorkingVolume {
                    candidates.append((set, set.completedAt ?? workout.startedAt))
                }
            }
        }
        guard !candidates.isEmpty else { return [] }

        var result: [AllTimeBest] = []
        if let best = candidates.max(by: { ($0.set.effectiveLoad ?? 0) < ($1.set.effectiveLoad ?? 0) }),
           (best.set.effectiveLoad ?? 0) > 0 {
            result.append(AllTimeBest(kind: .heaviestWeight, set: best.set, date: best.date))
        }
        if let best = candidates.max(by: { ($0.set.totalVolume ?? 0) < ($1.set.totalVolume ?? 0) }),
           (best.set.totalVolume ?? 0) > 0 {
            result.append(AllTimeBest(kind: .bestSetVolume, set: best.set, date: best.date))
        }
        if let best = candidates.max(by: { ($0.set.estimated1RM ?? 0) < ($1.set.estimated1RM ?? 0) }),
           (best.set.estimated1RM ?? 0) > 0 {
            result.append(AllTimeBest(kind: .best1RM, set: best.set, date: best.date))
        }
        return result
    }

    /// The workout's final records for one exercise: for each kind, the single
    /// best set of the session if it beat the historical baseline.
    static func summaryAwards(for workoutExercise: WorkoutExerciseModel, baseline: ExerciseRecordBaseline?) -> [(kind: RecordKind, set: SetModel)] {
        guard let baseline, baseline.hasHistory else { return [] }
        let done = workoutExercise.sets.filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        guard !done.isEmpty else { return [] }

        var result: [(kind: RecordKind, set: SetModel)] = []
        if let best = done.max(by: { ($0.effectiveLoad ?? 0) < ($1.effectiveLoad ?? 0) }),
           let load = best.effectiveLoad, load > 0, load > baseline.maxLoad {
            result.append((.heaviestWeight, best))
        }
        if let best = done.max(by: { ($0.totalVolume ?? 0) < ($1.totalVolume ?? 0) }),
           let volume = best.totalVolume, volume > 0, volume > baseline.maxSetVolume {
            result.append((.bestSetVolume, best))
        }
        if let best = done.max(by: { ($0.estimated1RM ?? 0) < ($1.estimated1RM ?? 0) }),
           let oneRM = best.estimated1RM, oneRM > 0, oneRM > baseline.max1RM {
            result.append((.best1RM, best))
        }
        return result
    }
}
