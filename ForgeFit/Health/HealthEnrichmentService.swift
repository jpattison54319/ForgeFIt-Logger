import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// The calls HealthEnrichmentService makes against Apple Health — a
/// protocol so enrichment logic is unit-testable with canned data.
protocol HealthEnriching: Sendable {
    func importSnapshot(from start: Date, to end: Date, modality: CardioKind) async -> CardioSnapshot
    func bodyMassKg(near date: Date, toleranceDays: Int) async -> Double?
    func workoutUUID(matchingStart start: Date, end: Date, tolerance: TimeInterval) async -> UUID?
}

extension HealthService: HealthEnriching {}

/// Refills Health-derived fields on RESTORED workouts from the user's own
/// Apple Health store. This is the compliant half of cross-device
/// continuity: the iCloud backup carries no health data (5.1.3(ii)); Apple
/// Health carries it via Apple's Health-in-iCloud sync, under the user's
/// control — so on a new device we re-read it from there.
///
/// Idempotent nil-only fills (the WorkoutFinisher backfill pattern): a
/// field that already has a value is never overwritten.
@MainActor
final class HealthEnrichmentService {
    struct Summary {
        var workoutsEnriched = 0
        var sessionsEnriched = 0
        var setsBodyweightFilled = 0
        var healthUUIDsRelinked = 0
    }

    private let health: any HealthEnriching

    init(health: any HealthEnriching = HealthService.shared) {
        self.health = health
    }

    func enrich(workoutIDs: [UUID], in context: ModelContext) async -> Summary {
        var summary = Summary()
        let ids = Set(workoutIDs)
        let workouts = ((try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? [])
            .filter { ids.contains($0.id) && $0.deletedAt == nil }

        for workout in workouts {
            let end = workout.endedAt ?? workout.startedAt.addingTimeInterval(45 * 60)

            // Workout-level metrics: fill nils only.
            if workout.avgHR == nil || workout.maxHR == nil || workout.activeEnergyKcal == nil {
                let snapshot = await health.importSnapshot(from: workout.startedAt, to: end, modality: .other)
                if workout.avgHR == nil, let hr = snapshot.avgHR { workout.avgHR = hr }
                if workout.maxHR == nil, let max = snapshot.maxHR { workout.maxHR = max }
                if workout.activeEnergyKcal == nil, let energy = snapshot.activeEnergyKcal { workout.activeEnergyKcal = energy }
                if snapshot.hasData { summary.workoutsEnriched += 1 }
            }
            if workout.hrZoneSeconds.isEmpty, let avgHR = workout.avgHR,
               let duration = workout.endedAt.map({ Int($0.timeIntervalSince(workout.startedAt)) }) {
                workout.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: avgHR, durationSeconds: duration)
            }

            // Re-link the HKWorkout so the Health importer's strong dedup
            // key protects this workout again.
            if workout.hkWorkoutUUID == nil,
               let uuid = await health.workoutUUID(matchingStart: workout.startedAt, end: end, tolerance: 120) {
                workout.hkWorkoutUUID = uuid
                summary.healthUUIDsRelinked += 1
            }

            // Cardio sessions: window metrics, then series/zones self-heal.
            for session in workout.cardioSessions where session.deletedAt == nil {
                let sessionStart = session.liveStartedAt ?? session.startedAt
                let sessionEnd = session.endedAt ?? end
                if session.avgHR == nil || session.maxHR == nil || session.activeEnergyKcal == nil {
                    let kind = CardioKind(rawValue: session.modality) ?? .other
                    let snapshot = await health.importSnapshot(from: sessionStart, to: sessionEnd, modality: kind)
                    if session.avgHR == nil, let hr = snapshot.avgHR { session.avgHR = hr }
                    if session.maxHR == nil, let max = snapshot.maxHR { session.maxHR = max }
                    if session.activeEnergyKcal == nil, let energy = snapshot.activeEnergyKcal { session.activeEnergyKcal = energy }
                    if snapshot.hasData { summary.sessionsEnriched += 1 }
                }
                if session.sampleSeriesJSON == nil {
                    // Rebuilds the HR/distance series and measured zones from
                    // HealthKit + restored route points. `hadManualIntervalPlan`
                    // guards restored splits from the auto-detector, which
                    // would otherwise DELETE them.
                    await CardioSeriesService.finalize(
                        session: session,
                        hadManualIntervalPlan: !session.splits.isEmpty || session.intervalsAutoApplied,
                        in: context
                    )
                }
            }

            // Bodyweight-mode sets need body mass for volume math.
            for exercise in workout.exercises {
                for set in exercise.sets where set.weightMode != .external && set.bodyweightKg == nil {
                    let anchor = set.completedAt ?? workout.startedAt
                    if let mass = await health.bodyMassKg(near: anchor, toleranceDays: 7) {
                        set.bodyweightKg = mass
                        set.recomputeDerivedMetrics()
                        summary.setsBodyweightFilled += 1
                    }
                }
            }
            workout.recomputeTotalVolume()
        }

        try? context.save()
        return summary
    }
}
