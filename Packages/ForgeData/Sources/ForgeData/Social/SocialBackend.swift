import Foundation

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
    func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date) async throws
    func unpublishWorkout(id: UUID) async throws
    /// A user's recent shared workouts, newest first.
    func recentWorkouts(for id: SocialUserID, limit: Int) async throws -> [SocialWorkoutRef]
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

    // MARK: Leaderboards
    func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int) async throws -> [SocialLeaderboardEntry]
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
