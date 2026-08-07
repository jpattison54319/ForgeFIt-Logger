import ForgeData
import Foundation

/// One workout ready to publish. `publishedAt` is stamped with the workout's
/// end time, not "now": profile lists order by `publishedAt` descending, so
/// backfilled history slots in beneath live-published workouts in true
/// training order instead of arriving as one same-instant clump on top.
/// `sourceUpdatedAt` (the workout's `updatedAt`) rides along as the staleness
/// watermark — republishing an edit refreshes content without moving the row.
struct SocialBackfillItem {
    let dto: SharedWorkoutDTO
    let summary: SharedWorkoutSummary
    let publishedAt: Date
    let sourceUpdatedAt: Date
}

/// The id + local-clock pair reconcile diffs against the remote refs: absent
/// remotely → publish; present but `updatedAt` newer than the remote
/// watermark → republish.
struct SocialShareStamp {
    let id: UUID
    let updatedAt: Date
}

/// Projects the local training log into the publishable backlog for
/// `SocialService.reconcileSharedWorkouts`. Eligibility is the product rule for the
/// whole social surface: **finished in ForgeFit** — completed, not deleted,
/// and not imported history (Hevy/Strong/CSV files, Apple Health, GPX; the
/// `isImportedHistory` definition XP and trophies already gate on). Someone
/// else's app logged those — sharing them as ForgeFit training would misstate
/// the record. Input order is preserved, so pass workouts newest-first.
enum SocialBackfill {
    /// The share-eligibility filter alone (no DTO mapping) — what the
    /// reconcile pass diffs against the remote id set each launch. Kept
    /// relationship-free so a settled log costs three field reads per row.
    /// The single share-eligibility predicate — the hearts row gates on this
    /// too, so "can have hearts" can never drift from "gets published".
    static func isEligible(_ workout: WorkoutModel) -> Bool {
        workout.endedAt != nil && workout.deletedAt == nil && !workout.isImportedHistory
    }

    static func eligibleWorkouts(_ workouts: [WorkoutModel]) -> [WorkoutModel] {
        workouts.filter(isEligible)
    }

    static func items(from workouts: [WorkoutModel], exerciseNames: [UUID: String]) -> [SocialBackfillItem] {
        workouts.compactMap { workout in
            guard let endedAt = workout.endedAt,
                  workout.deletedAt == nil,
                  !workout.isImportedHistory else { return nil }
            let dto = SocialWorkoutMapper.shared(from: workout, exerciseNames: exerciseNames)
            // Same emptiness rule as the live finish path: a workout with no
            // exercises and no cardio has nothing to show on a profile.
            guard !(dto.exercises.isEmpty && dto.cardioSessions.isEmpty) else { return nil }
            return SocialBackfillItem(
                dto: dto, summary: dto.summary,
                publishedAt: endedAt, sourceUpdatedAt: workout.updatedAt
            )
        }
    }
}
