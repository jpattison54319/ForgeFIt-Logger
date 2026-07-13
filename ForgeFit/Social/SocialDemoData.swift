import ForgeData
import Foundation

/// Seeds `MockSocialBackend` with a few followable friends so the social
/// surfaces are demoable in the simulator (no iCloud). Demo-only — the real
/// app resolves everything from the CloudKit public database.
enum SocialDemoData {
    static func seed(into backend: MockSocialBackend) async {
        let now = Date()
        await backend.seed(
            profile: SocialProfile(
                userID: SocialUserID("friend-alex"), handle: "alexlifts", displayName: "Alex Rivera",
                totalXP: 4200, workoutCount: 128, lifetimeHours: 96,
                stats: SocialStats(lifetimeVolumeKg: 842_500, bestE1RMKg: 180, cardioDistanceMeters: 40_000, cardioMinutes: 220, yogaMinutes: 0),
                updatedAt: now),
            workouts: [
                workout("Push Day A", daysAgo: 1, from: now, exercises: [
                    ("Bench Press", [(100, 5), (100, 5), (102.5, 4)]),
                    ("Overhead Press", [(60, 6), (60, 6)]),
                    ("Incline DB Press", [(34, 10), (34, 9)]),
                ]),
                workout("Pull Day A", daysAgo: 3, from: now, exercises: [
                    ("Deadlift", [(180, 3), (180, 3)]),
                    ("Barbell Row", [(90, 8), (90, 8)]),
                    ("Lat Pulldown", [(70, 12), (70, 11)]),
                ]),
            ],
            follow: true)

        await backend.seed(
            profile: SocialProfile(
                userID: SocialUserID("friend-mia"), handle: "miaruns", displayName: "Mia Chen",
                totalXP: 2600, workoutCount: 84, lifetimeHours: 71,
                stats: SocialStats(lifetimeVolumeKg: 310_000, bestE1RMKg: 110, cardioDistanceMeters: 512_000, cardioMinutes: 3_100, yogaMinutes: 240),
                updatedAt: now),
            workouts: [
                workout("Full Body B", daysAgo: 2, from: now, exercises: [
                    ("Back Squat", [(90, 5), (90, 5), (90, 5)]),
                    ("Romanian Deadlift", [(80, 8), (80, 8)]),
                    ("Pull-up", [(0, 8), (0, 7)]),
                ]),
            ],
            follow: true)

        await backend.seed(
            profile: SocialProfile(
                userID: SocialUserID("friend-sam"), handle: "samzen", displayName: "Sam Okafor",
                totalXP: 1900, workoutCount: 140, lifetimeHours: 88,
                stats: SocialStats(lifetimeVolumeKg: 120_000, bestE1RMKg: 90, cardioDistanceMeters: 60_000, cardioMinutes: 400, yogaMinutes: 3_600),
                updatedAt: now),
            workouts: [
                workout("Mobility + Core", daysAgo: 1, from: now, exercises: [
                    ("Goblet Squat", [(24, 12), (24, 12)]),
                    ("Kettlebell Swing", [(24, 15), (24, 15)]),
                ]),
            ],
            follow: true)
    }

    /// Fabricates a shared workout with plausible derived aggregates.
    private static func workout(
        _ title: String, daysAgo: Int, from now: Date,
        exercises: [(name: String, sets: [(weight: Double, reps: Int)])]
    ) -> (dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date) {
        let started = now.addingTimeInterval(Double(-daysAgo) * 86_400)
        let ended = started.addingTimeInterval(3_600)
        let dtoExercises = exercises.enumerated().map { exIndex, ex in
            SharedExerciseDTO(
                id: UUID(), exerciseID: UUID(), name: ex.name, position: exIndex, supersetGroup: nil,
                sets: ex.sets.enumerated().map { setIndex, s in
                    SharedSetDTO(
                        id: UUID(), position: setIndex, setType: "working", weightMode: s.weight == 0 ? "bodyweight" : "external",
                        reps: s.reps, weightKg: s.weight == 0 ? nil : s.weight, rpe: nil, rir: nil,
                        durationSeconds: nil, holdSeconds: nil, partialReps: nil, addedWeight: nil, assistanceWeight: nil,
                        isUnilateral: false, implementWeight: nil, limbCount: 2, isEccentric: false, isPaused: false,
                        machineSettingsJSON: nil, miniRepsJSON: nil, side2Reps: nil, side2MiniRepsJSON: nil,
                        plannedMiniSetCount: nil, plannedMiniRepsJSON: nil,
                        effectiveLoad: s.weight, totalVolume: max(s.weight, 1) * Double(s.reps),
                        estimated1RM: s.weight * (1 + Double(s.reps) / 30),
                        completedAt: started.addingTimeInterval(Double(setIndex) * 120))
                })
        }
        let dto = SharedWorkoutDTO(id: UUID(), title: title, startedAt: started, endedAt: ended, exercises: dtoExercises)
        return (dto, dto.summary, started.addingTimeInterval(3_600))
    }
}
