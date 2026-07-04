import ForgeCore
import ForgeData
import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Shared end-of-workout pipeline, used by both the on-phone logger and
/// watch-initiated finishes so the two paths can't drift:
/// 1. auto-complete any running cardio segment (+ HealthKit auto-fill),
/// 2. stamp session health metrics onto the workout (watch-live metrics win,
///    HealthKit window query as fallback),
/// 3. write the HKWorkout back to Apple Health (unless the watch already did),
/// 4. kick a cloud sync.
enum WorkoutFinisher {

    @MainActor
    static func finish(
        _ workout: WorkoutModel,
        in context: ModelContext,
        watchMetrics: WatchLiveMetrics? = nil,
        watchSavedToHealth: Bool = false
    ) {
        let now = Date()

        // 1. Auto-complete running cardio segments and pull their metrics.
        for session in workout.cardioSessions where session.liveStartedAt != nil && session.endedAt == nil {
            let start = session.liveStartedAt ?? session.startedAt
            session.endedAt = now
            session.durationSeconds = max(1, Int(now.timeIntervalSince(start)))
            let kind = CardioKind.from(modality: session.modality)
            Task { @MainActor in
                let snap = await HealthService.shared.importSnapshot(from: start, to: now, modality: kind)
                if let hr = snap.avgHR { session.avgHR = hr }
                if let mx = snap.maxHR { session.maxHR = mx }
                if let e = snap.activeEnergyKcal { session.activeEnergyKcal = e }
                if let dist = snap.distanceMeters { session.distanceMeters = dist }
                session.hrZoneSeconds = CardioMetrics.estimatedZoneSecondsArray(avgHR: session.avgHR, durationSeconds: session.durationSeconds)
                try? context.save()
            }
        }

        // 2. Session metrics: live watch data is the best source; otherwise
        //    query HealthKit for the workout window.
        if let watchMetrics {
            apply(watchMetrics, to: workout)
        }
        workout.endedAt = now
        workout.recomputeTotalVolume()
        XPService.awardXPIfNeeded(for: workout, in: context, now: now)
        try? context.save()

        let start = workout.startedAt
        if watchMetrics == nil {
            Task { @MainActor in
                let snap = await HealthService.shared.importSnapshot(from: start, to: now, modality: .other)
                if workout.avgHR == nil, let hr = snap.avgHR { workout.avgHR = hr }
                if workout.maxHR == nil, let mx = snap.maxHR { workout.maxHR = mx }
                if workout.activeEnergyKcal == nil, let e = snap.activeEnergyKcal { workout.activeEnergyKcal = e }
                try? context.save()
            }
        }

        // 3. Write to Apple Health — skipped when the watch's live workout
        //    builder already saved the session (avoids double-counting).
        let writeEnabled = UserDefaults.standard.object(forKey: "healthWriteEnabled") == nil
            || UserDefaults.standard.bool(forKey: "healthWriteEnabled")
        if writeEnabled && !watchSavedToHealth {
            let energy = workout.activeEnergyKcal
                ?? workout.cardioSessions.compactMap { $0.activeEnergyKcal }.reduce(0, +).nonZero
            let distance = workout.cardioSessions.compactMap { $0.distanceMeters }.reduce(0, +).nonZero
            let cardioKind = workout.cardioSessions.first.map { CardioKind.from(modality: $0.modality) }
            let pureCardio = !workout.exercises.isEmpty
                && workout.exercises.allSatisfy { we in workout.cardioSessions.contains { $0.workoutExerciseID == we.id } }
            Task {
                await HealthService.shared.saveWorkout(
                    from: start, to: now,
                    isCardio: pureCardio, modality: cardioKind,
                    energyKcal: energy, distanceMeters: distance
                )
            }
        }

        // Tell the watch the session is over and refresh its snapshot.
        // A finished session means today's streak is safe — drop the nudge.
        Task { @MainActor in NotificationScheduler.shared.cancelStreakNudge() }

        WatchLink.shared.sendCommand(.workoutFinished)
        WatchLink.shared.publishState()
        endLiveSurfaces()
    }

    @MainActor
    static func discard(_ workout: WorkoutModel, in context: ModelContext) {
        let now = Date()
        workout.updatedAt = now
        workout.deletedAt = now
        try? context.save()
        WatchLink.shared.sendCommand(.discardWorkout)
        WatchLink.shared.publishState()
        endLiveSurfaces()
    }

    static func apply(_ metrics: WatchLiveMetrics, to workout: WorkoutModel) {
        if let hr = metrics.avgHR { workout.avgHR = hr }
        if let mx = metrics.maxHR { workout.maxHR = mx }
        if let e = metrics.activeEnergyKcal { workout.activeEnergyKcal = e }
        if metrics.hrZoneSeconds.contains(where: { $0 > 0 }) {
            workout.hrZoneSeconds = metrics.hrZoneSeconds
        }
    }

    @MainActor
    private static func endLiveSurfaces() {
        WorkoutActivityController.shared.end()
        RestTimerController.shared.skip()
        IntervalRunnerHub.shared.stop()
        WatchLink.shared.clearLiveMetrics()
        ForgeFitWidgetSnapshotStore.save(ForgeFitWidgetSnapshot(mode: .idle))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: "ForgeFitLauncher")
        #endif
    }
}

private extension Double {
    var nonZero: Double? { self > 0 ? self : nil }
}
