import ForgeData
import Foundation

/// Resolves one heart-rate truth for history presentation and derived metrics.
/// Fresh HealthKit samples win; stored values remain the fallback for imported,
/// manual, or no-permission workouts. A timed modality shares the whole metric
/// only when its clock spans the workout; narrower cardio, yoga, and
/// conditioning sections keep metrics from their own timestamp window.
enum WorkoutHeartRateResolution {
    struct Metrics: Equatable {
        let averageBPM: Int?
        let maximumBPM: Int?
        let activeEnergyKcal: Double?
        let zoneSeconds: [Int]?

        init(
            averageBPM: Int?,
            maximumBPM: Int?,
            activeEnergyKcal: Double? = nil,
            zoneSeconds: [Int]? = nil
        ) {
            self.averageBPM = averageBPM
            self.maximumBPM = maximumBPM
            self.activeEnergyKcal = activeEnergyKcal
            self.zoneSeconds = zoneSeconds
        }

        var hasData: Bool { averageBPM != nil || maximumBPM != nil }
    }

    static func workoutMetrics(
        for workout: WorkoutModel,
        samples: [(date: Date, bpm: Int)]
    ) -> Metrics {
        let measured: CardioBlockSupport.HeartRateSummary?
        if let end = workout.endedAt, end > workout.startedAt {
            measured = CardioBlockSupport.heartRateSummary(
                samples: samples,
                window: workout.startedAt...end
            )
        } else {
            measured = nil
        }
        return Metrics(
            averageBPM: measured?.averageBPM ?? workout.avgHR,
            maximumBPM: measured?.maximumBPM ?? workout.maxHR,
            activeEnergyKcal: workout.activeEnergyKcal,
            zoneSeconds: workout.hrZoneSeconds.contains(where: { $0 > 0 })
                ? workout.hrZoneSeconds
                : nil
        )
    }

    static func sessionMetrics(
        for session: CardioSessionModel,
        in workout: WorkoutModel,
        samples: [(date: Date, bpm: Int)]
    ) -> Metrics {
        if sharesWholeWorkoutWindow(session, in: workout) {
            let whole = workoutMetrics(for: workout, samples: samples)
            return Metrics(
                averageBPM: whole.averageBPM ?? session.avgHR,
                maximumBPM: whole.maximumBPM ?? session.maxHR,
                activeEnergyKcal: whole.activeEnergyKcal ?? session.activeEnergyKcal,
                zoneSeconds: whole.zoneSeconds
                    ?? (session.hrZoneSeconds.contains(where: { $0 > 0 }) ? session.hrZoneSeconds : nil)
            )
        }

        let measured = blockMetrics(for: session, samples: samples)
        return Metrics(
            averageBPM: measured?.averageBPM ?? session.avgHR,
            maximumBPM: measured?.maximumBPM ?? session.maxHR,
            activeEnergyKcal: session.activeEnergyKcal,
            zoneSeconds: session.hrZoneSeconds.contains(where: { $0 > 0 })
                ? session.hrZoneSeconds
                : nil
        )
    }

    /// Applies fresh, local HealthKit truth to the existing local-only metric
    /// fields so Insights, load, efficiency, exports, and history agree after
    /// the detail refresh. Backup/social mappers already omit these fields.
    @discardableResult
    static func reconcile(
        workout: WorkoutModel,
        samples: [(date: Date, bpm: Int)]
    ) -> Bool {
        guard !samples.isEmpty else { return false }
        var changed = false

        if let end = workout.endedAt,
           end > workout.startedAt,
           let measured = CardioBlockSupport.heartRateSummary(
               samples: samples,
               window: workout.startedAt...end
           ) {
            changed = assign(measured, average: &workout.avgHR, maximum: &workout.maxHR) || changed
        }

        for session in workout.cardioSessions where session.deletedAt == nil && session.endedAt != nil {
            let measured: CardioBlockSupport.HeartRateSummary?
            if sharesWholeWorkoutWindow(session, in: workout),
               let average = workout.avgHR,
               let maximum = workout.maxHR {
                measured = .init(averageBPM: average, maximumBPM: maximum)
            } else {
                measured = blockMetrics(for: session, samples: samples)
            }
            if let measured {
                changed = assign(measured, average: &session.avgHR, maximum: &session.maxHR) || changed
            }
            if sharesWholeWorkoutWindow(session, in: workout),
               let energy = workout.activeEnergyKcal,
               session.activeEnergyKcal != energy {
                session.activeEnergyKcal = energy
                changed = true
            }
            if sharesWholeWorkoutWindow(session, in: workout),
               workout.hrZoneSeconds.contains(where: { $0 > 0 }),
               session.hrZoneSeconds != workout.hrZoneSeconds {
                session.hrZoneSeconds = workout.hrZoneSeconds
                changed = true
            }
        }
        return changed
    }

    static func isSoleTimedModality(
        _ session: CardioSessionModel,
        in workout: WorkoutModel
    ) -> Bool {
        let completed = workout.cardioSessions.filter {
            $0.deletedAt == nil && $0.endedAt != nil
        }
        guard completed.count == 1, completed.first?.id == session.id else { return false }
        let modalities = WorkoutPresentationPlan.make(for: workout).modalities
        return modalities.count == 1 && !modalities.contains(.strength)
    }

    /// A single timed modality can still occupy only part of the saved workout
    /// (for example, AX400 started after setup and ended before the user saved).
    /// Only genuinely coextensive windows may reuse the whole-workout average.
    static func sharesWholeWorkoutWindow(
        _ session: CardioSessionModel,
        in workout: WorkoutModel,
        tolerance: TimeInterval = 60
    ) -> Bool {
        guard isSoleTimedModality(session, in: workout) else { return false }
        guard let workoutEnd = workout.endedAt,
              let sessionWindow = CardioBlockSupport.blockWindow(
                  startedAt: session.startedAt,
                  liveStartedAt: session.liveStartedAt,
                  endedAt: session.endedAt,
                  durationSeconds: session.durationSeconds
              ) else { return false }
        return abs(sessionWindow.lowerBound.timeIntervalSince(workout.startedAt)) <= tolerance
            && abs(sessionWindow.upperBound.timeIntervalSince(workoutEnd)) <= tolerance
    }

    private static func blockMetrics(
        for session: CardioSessionModel,
        samples: [(date: Date, bpm: Int)]
    ) -> CardioBlockSupport.HeartRateSummary? {
        guard let window = CardioBlockSupport.blockWindow(
            startedAt: session.startedAt,
            liveStartedAt: session.liveStartedAt,
            endedAt: session.endedAt,
            durationSeconds: session.durationSeconds
        ) else { return nil }
        return CardioBlockSupport.heartRateSummary(samples: samples, window: window)
    }

    private static func assign(
        _ measured: CardioBlockSupport.HeartRateSummary,
        average: inout Int?,
        maximum: inout Int?
    ) -> Bool {
        guard average != measured.averageBPM || maximum != measured.maximumBPM else { return false }
        average = measured.averageBPM
        maximum = measured.maximumBPM
        return true
    }
}
