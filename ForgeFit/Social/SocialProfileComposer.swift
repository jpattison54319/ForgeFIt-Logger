import ForgeData
import Foundation

/// Builds the local user's shareable `ProfileSnapshot` from the on-device
/// training log. Uses only training aggregates (volume, e1RM, minutes,
/// distance) and XP — never heart rate, readiness, sleep, or body weight.
enum SocialProfileComposer {
    static func snapshot(
        workouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        totalXP: Int,
        now: Date = Date()
    ) -> ProfileSnapshot {
        let analytics = TrainingAnalytics(workouts: workouts, exercises: exercises)
        let completed = analytics.completed

        var strengthVolume = 0.0
        var cardioMinutes = 0.0
        var cardioDistance = 0.0
        var yogaMinutes = 0.0
        var totalSeconds = 0

        for workout in completed {
            let summary = analytics.summary(for: workout)
            totalSeconds += summary.durationSeconds
            if !summary.isCardio { strengthVolume += summary.volume }
            for session in workout.cardioSessions where session.deletedAt == nil {
                let minutes = Double(session.durationSeconds ?? 0) / 60
                if session.modality == "yoga" {
                    yogaMinutes += minutes
                } else {
                    cardioMinutes += minutes
                    cardioDistance += session.distanceMeters ?? 0
                }
            }
        }

        let bestE1RM = analytics.records().map(\.best1RM).max() ?? 0

        return ProfileSnapshot(
            totalXP: totalXP,
            workoutCount: completed.count,
            lifetimeHours: Double(totalSeconds) / 3600,
            stats: SocialStats(
                lifetimeVolumeKg: strengthVolume,
                bestE1RMKg: bestE1RM,
                cardioDistanceMeters: cardioDistance,
                cardioMinutes: cardioMinutes,
                yogaMinutes: yogaMinutes
            ),
            now: now
        )
    }
}
