import Foundation

/// One heart on a shared workout. `likedAt` orders the hearts row and its
/// full list (newest first); ties break on userID so ordering is stable.
public struct SocialLike: Sendable, Equatable {
    public let userID: SocialUserID
    public let likedAt: Date

    public init(userID: SocialUserID, likedAt: Date) {
        self.userID = userID
        self.likedAt = likedAt
    }
}

/// The transport boundary for the social layer. The UI depends only on this
/// protocol, so the entire feature can be built and demoed against
/// `MockSocialBackend` in the simulator (which has no iCloud account), and the
/// CloudKit public-database implementation drops in behind the same interface.
///
/// Every method is identity-scoped by the backend itself: the backend knows the
/// current user (`currentUserID`), so callers never pass "me".
public protocol SocialBackend: Sendable {

    // MARK: Identity
    /// The stable opaque id for the signed-in user (CloudKit user record).
    func currentUserID() async throws -> SocialUserID

    // MARK: Profile
    /// Create or update the local user's public profile.
    func upsertMyProfile(_ profile: SocialProfile) async throws
    func profile(for id: SocialUserID) async throws -> SocialProfile?
    func profile(forHandle handle: String) async throws -> SocialProfile?
    /// Atomically claim `handle` for the local user. Returns false if another
    /// user already holds it. Idempotent for the current owner.
    func claimHandle(_ handle: String) async throws -> Bool

    // MARK: Shared workouts
    /// Upsert keyed by `dto.id`. `publishedAt` is the list-ordering key
    /// (stamped with the workout's end time so profiles read in training
    /// order); `sourceUpdatedAt` is the local workout's `updatedAt`, the
    /// staleness watermark reconcile compares against.
    func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date, sourceUpdatedAt: Date) async throws
    func unpublishWorkout(id: UUID) async throws
    /// A user's shared workouts, newest first. `before` is keyset pagination:
    /// non-nil returns only workouts published strictly earlier, so page N+1
    /// passes the last ref's `publishedAt` from page N. Refs carry summaries
    /// only — the full payload stays behind `workoutDetail(id:)`.
    func recentWorkouts(for id: SocialUserID, limit: Int, before: Date?) async throws -> [SocialWorkoutRef]
    func workoutDetail(id: UUID) async throws -> SharedWorkoutDTO?

    // MARK: Follow graph
    func follow(_ id: SocialUserID) async throws
    func unfollow(_ id: SocialUserID) async throws
    func following() async throws -> [SocialUserID]
    func isFollowing(_ id: SocialUserID) async throws -> Bool

    // MARK: Likes
    func setLike(_ liked: Bool, workoutID: UUID) async throws
    func likeCount(workoutID: UUID) async throws -> Int
    func hasLiked(workoutID: UUID) async throws -> Bool
    /// Everyone who hearted a workout, newest first. Complete — backends must
    /// page through server cursors, not return one truncated batch (the
    /// hearts row derives its count from this list; a partial list shows a
    /// wrong count AND a wrong "most recent" name).
    func likers(workoutID: UUID) async throws -> [SocialLike]

    // MARK: Leaderboards
    func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int) async throws -> [SocialLeaderboardEntry]

    // MARK: Account deletion
    /// Permanently deletes every record the local user created: profile,
    /// handle claim, shared workouts, follows, and likes. Records *other*
    /// users created about them (their follows, their likes) are not the
    /// local user's to delete; they become unreachable once the profile and
    /// workouts are gone. Idempotent — a retry after a partial failure
    /// finishes the job.
    func deleteAllMyData() async throws
}

public extension SocialBackend {
    /// First page: newest `limit` workouts.
    func recentWorkouts(for id: SocialUserID, limit: Int) async throws -> [SocialWorkoutRef] {
        try await recentWorkouts(for: id, limit: limit, before: nil)
    }

    /// Publish with the watermark defaulted to the publish moment — for
    /// callers (seeds, tests) that don't track a separate source clock.
    func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date) async throws {
        try await publishWorkout(dto, summary: summary, publishedAt: publishedAt, sourceUpdatedAt: publishedAt)
    }
}

/// Handle rules shared by every backend: 3–20 chars, lowercase a–z/0–9/_,
/// must start with a letter. Normalization lowercases and trims a leading "@".
public enum SocialHandle {
    public static let minLength = 3
    public static let maxLength = 20

    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    public static func isValid(_ raw: String) -> Bool {
        let s = normalize(raw)
        guard s.count >= minLength, s.count <= maxLength else { return false }
        guard let first = s.first, first.isLetter else { return false }
        return s.allSatisfy { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" }
    }
}
