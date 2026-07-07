import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// Flexibility exposure: seconds of stretch per body region. The metric the
/// yoga pillar stands on, and deliberately the only claim it makes — weekly
/// stretch *duration per muscle group* is what the ROM literature supports
/// (Thomas et al. 2018, Int J Sports Med; ACSM: ≥2–3 sessions/week). No
/// injury-prevention or medical claims anywhere.
enum FlexibilityAnalytics {

    /// Weekly per-region "effective dose" marker: ~10 minutes/week per region
    /// is where ROM gains become reliable in the pooled literature.
    static let weeklyEffectiveDoseSeconds = 600

    // MARK: - Per-session exposure (computed once at completion)

    /// Seconds credited to each region by a completed guided session. Poses
    /// credit their primary regions in full and secondary regions at half —
    /// the same convention muscle volume uses.
    ///
    /// Guided sessions: each recorded split is matched to its pose by label
    /// (robust against skips, back-tracking, and repeated poses — a repeated
    /// label is the same pose, so the regions are identical) and credits its
    /// ACTUAL hold seconds. Unguided/manual logs have no splits and fall back
    /// to the plan's nominal durations scaled to the logged duration.
    @MainActor
    static func exposure(
        plan: YogaFlowPlan,
        session: CardioSessionModel,
        context: ModelContext
    ) -> [String: Int] {
        let expanded = YogaFlowRunner.expand(plan)
        guard !expanded.isEmpty else { return [:] }

        let splits = session.splits
        var result: [String: Double] = [:]

        func credit(_ step: YogaFlowPlan.PoseStep, seconds: Double) {
            let regions = regions(for: step, context: context)
            for region in regions.primary {
                result[MuscleTaxonomy.canonical(region), default: 0] += seconds
            }
            for region in regions.secondary {
                result[MuscleTaxonomy.canonical(region), default: 0] += seconds * 0.5
            }
        }

        if splits.isEmpty {
            // Manual scale: distribute the logged duration proportionally.
            let nominalTotal = expanded.reduce(0) { $0 + $1.seconds }
            let scale: Double = {
                guard let logged = session.durationSeconds, nominalTotal > 0 else { return 1 }
                return Double(logged) / Double(nominalTotal)
            }()
            for step in expanded {
                credit(step.poseStep, seconds: Double(step.seconds) * scale)
            }
        } else {
            let stepByLabel = Dictionary(
                expanded.map { ($0.displayName, $0.poseStep) },
                uniquingKeysWith: { first, _ in first }
            )
            for split in splits {
                guard let label = split.label, let step = stepByLabel[label] else { continue }
                credit(step, seconds: Double(split.durationSeconds))
            }
        }
        return result.mapValues { Int($0.rounded()) }.filter { $0.value > 0 }
    }

    /// Compute and freeze the exposure snapshot onto the session (JSON), so
    /// analytics never re-derive it from splits.
    @MainActor
    static func stampExposure(
        plan: YogaFlowPlan,
        session: CardioSessionModel,
        context: ModelContext
    ) {
        let exposure = exposure(plan: plan, session: session, context: context)
        guard !exposure.isEmpty,
              let data = try? JSONEncoder().encode(exposure),
              let json = String(data: data, encoding: .utf8) else { return }
        session.flexibilityExposureJSON = json
    }

    static func decodeExposure(_ json: String?) -> [String: Int] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: Int].self, from: data)) ?? [:]
    }

    /// A pose's stretch-target regions: bundled catalog first (seeded poses),
    /// else the library row's muscles (custom poses).
    @MainActor
    private static func regions(
        for step: YogaFlowPlan.PoseStep,
        context: ModelContext
    ) -> (primary: [String], secondary: [String]) {
        if let pose = YogaPoseCatalog.pose(forSlug: step.poseSlug) {
            return (pose.primaryMuscles, pose.secondaryMuscles)
        }
        let poseID = step.poseID
        let row = try? context.fetch(
            FetchDescriptor<ExerciseLibraryModel>(predicate: #Predicate { $0.id == poseID })
        ).first
        guard let row else { return ([], []) }
        return (row.primaryMuscles, row.secondaryMuscles)
    }

    // MARK: - Aggregation (Insights / Statistics)

    struct RegionWeek: Identifiable {
        let region: String
        let seconds: Int
        var id: String { region }

        /// Progress toward the weekly effective dose, capped for display.
        var doseFraction: Double {
            min(1, Double(seconds) / Double(weeklyEffectiveDoseSeconds))
        }
    }

    /// Per-region seconds across yoga sessions in `range`, from the frozen
    /// per-session snapshots, plus timed sets on stretching-category
    /// exercises (the free-exercise-db's 123 stretches) so existing habits
    /// count without being reclassified.
    static func regionSeconds(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        range: ClosedRange<Date>
    ) -> [RegionWeek] {
        var totals: [String: Int] = [:]

        for workout in workouts where workout.deletedAt == nil {
            guard let ended = workout.endedAt, range.contains(ended) else { continue }
            for session in workout.cardioSessions where session.isYogaSession {
                for (region, seconds) in decodeExposure(session.flexibilityExposureJSON) {
                    totals[region, default: 0] += seconds
                }
            }
            // Stretching-category sets with a timed hold/duration.
            for we in workout.exercises {
                guard let exercise = exercises.first(where: { $0.id == we.exerciseID }),
                      exercise.category == "stretching" else { continue }
                let seconds = we.sets
                    .filter { $0.completedAt != nil }
                    .compactMap { $0.holdSeconds ?? $0.durationSeconds }
                    .reduce(0, +)
                guard seconds > 0 else { continue }
                for region in exercise.primaryMuscles {
                    totals[MuscleTaxonomy.canonical(region), default: 0] += seconds
                }
                for region in exercise.secondaryMuscles {
                    totals[MuscleTaxonomy.canonical(region), default: 0] += seconds / 2
                }
            }
        }
        return totals
            .map { RegionWeek(region: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Distinct days with any flexibility work in `range` — the ACSM
    /// consistency signal (≥2–3 sessions/week).
    static func sessionDays(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        range: ClosedRange<Date>,
        calendar: Calendar = .current
    ) -> Int {
        var days = Set<DateComponents>()
        for workout in workouts where workout.deletedAt == nil {
            guard let ended = workout.endedAt, range.contains(ended) else { continue }
            let hasYoga = workout.cardioSessions.contains { $0.isYogaSession }
            let hasStretch = workout.exercises.contains { we in
                guard let exercise = exercises.first(where: { $0.id == we.exerciseID }) else { return false }
                return exercise.category == "stretching"
                    && we.sets.contains { $0.completedAt != nil && ($0.holdSeconds ?? $0.durationSeconds ?? 0) > 0 }
            }
            if hasYoga || hasStretch {
                days.insert(calendar.dateComponents([.year, .month, .day], from: ended))
            }
        }
        return days.count
    }

    /// Total yoga minutes in `range`, split by style bucket.
    static func yogaMinutes(
        workouts: [WorkoutModel],
        range: ClosedRange<Date>
    ) -> (active: Int, restorative: Int) {
        var active = 0, restorative = 0
        for workout in workouts where workout.deletedAt == nil {
            guard let ended = workout.endedAt, range.contains(ended) else { continue }
            for session in workout.cardioSessions where session.isYogaSession {
                let minutes = (session.durationSeconds ?? 0) / 60
                if session.resolvedYogaStyle.isRestorative {
                    restorative += minutes
                } else {
                    active += minutes
                }
            }
        }
        return (active, restorative)
    }
}
