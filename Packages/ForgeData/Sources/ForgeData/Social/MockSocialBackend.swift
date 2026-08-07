import Foundation

/// In-memory `SocialBackend` for previews, tests, and simulator demos (no
/// iCloud account required). State lives in the actor; nothing persists. The
/// CloudKit implementation will mirror this behaviour over the public database.
public actor MockSocialBackend: SocialBackend {
    private let me: SocialUserID
    private var profiles: [SocialUserID: SocialProfile] = [:]
    private var handleRegistry: [String: SocialUserID] = [:]
    private var payloads: [UUID: SharedWorkoutDTO] = [:]
    private var refs: [SocialUserID: [SocialWorkoutRef]] = [:]
    private var follows: Set<SocialUserID> = []
    /// Hearts keyed by workout, each liker mapped to when they hearted —
    /// the timestamp orders the hearts row exactly like CloudKit's
    /// record `creationDate` does on device.
    private var likes: [UUID: [SocialUserID: Date]] = [:]

    public init(me: SocialUserID = SocialUserID("me")) {
        self.me = me
    }

    // MARK: Identity
    public func currentUserID() -> SocialUserID { me }

    // MARK: Profile
    public func upsertMyProfile(_ profile: SocialProfile) {
        profiles[me] = profile
        handleRegistry[SocialHandle.normalize(profile.handle)] = me
    }

    public func profile(for id: SocialUserID) -> SocialProfile? { profiles[id] }

    public func profile(forHandle handle: String) -> SocialProfile? {
        handleRegistry[SocialHandle.normalize(handle)].flatMap { profiles[$0] }
    }

    public func claimHandle(_ handle: String) throws -> Bool {
        let h = SocialHandle.normalize(handle)
        guard SocialHandle.isValid(h) else { throw SocialError.invalidHandle }
        if let owner = handleRegistry[h] { return owner == me }
        if let old = profiles[me]?.handle { handleRegistry[SocialHandle.normalize(old)] = nil }
        handleRegistry[h] = me
        profiles[me]?.handle = h
        return true
    }

    // MARK: Shared workouts
    public func publishWorkout(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date, sourceUpdatedAt: Date) {
        payloads[dto.id] = dto
        let ref = SocialWorkoutRef(
            id: dto.id, owner: me, title: dto.title,
            startedAt: dto.startedAt, publishedAt: publishedAt,
            sourceUpdatedAt: sourceUpdatedAt, summary: summary
        )
        var list = refs[me, default: []].filter { $0.id != dto.id }
        list.append(ref)
        refs[me] = list.sorted { $0.publishedAt > $1.publishedAt }
    }

    public func unpublishWorkout(id: UUID) {
        payloads[id] = nil
        for owner in refs.keys { refs[owner]?.removeAll { $0.id == id } }
    }

    public func recentWorkouts(for id: SocialUserID, limit: Int, before: Date?) -> [SocialWorkoutRef] {
        var list = refs[id, default: []]
        if let before { list = list.filter { $0.publishedAt < before } }
        return Array(list.prefix(limit))
    }

    public func workoutDetail(id: UUID) -> SharedWorkoutDTO? { payloads[id] }

    // MARK: Follow graph
    public func follow(_ id: SocialUserID) { if id != me { follows.insert(id) } }
    public func unfollow(_ id: SocialUserID) { follows.remove(id) }
    public func following() -> [SocialUserID] { Array(follows) }
    public func isFollowing(_ id: SocialUserID) -> Bool { follows.contains(id) }

    // MARK: Likes
    public func setLike(_ liked: Bool, workoutID: UUID) {
        if liked { likes[workoutID, default: [:]][me] = Date() }
        else { likes[workoutID]?[me] = nil }
    }
    public func likeCount(workoutID: UUID) -> Int { likes[workoutID]?.count ?? 0 }
    public func hasLiked(workoutID: UUID) -> Bool { likes[workoutID]?[me] != nil }
    public func likers(workoutID: UUID) -> [SocialLike] {
        (likes[workoutID] ?? [:])
            .map { SocialLike(userID: $0.key, likedAt: $0.value) }
            .sorted {
                if $0.likedAt != $1.likedAt { return $0.likedAt > $1.likedAt }
                return $0.userID.rawValue < $1.userID.rawValue   // stable tiebreak
            }
    }

    // MARK: Leaderboards
    public func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int) -> [SocialLeaderboardEntry] {
        let candidates: [SocialProfile]
        switch scope {
        case .friends: candidates = (follows.union([me])).compactMap { profiles[$0] }
        case .global: candidates = Array(profiles.values)
        }
        return candidates
            .map { (profile: $0, value: $0.value(for: metric)) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .enumerated()
            .map { SocialLeaderboardEntry(profile: $0.element.profile, value: $0.element.value, rank: $0.offset + 1) }
    }

    // MARK: Account deletion

    /// Mirrors the CloudKit contract: only records *I* created disappear —
    /// my profile, handle claims, workouts, follows, and likes. Seeded
    /// friends and their content survive untouched.
    public func deleteAllMyData() {
        for ref in refs[me, default: []] { payloads[ref.id] = nil }
        refs[me] = nil
        follows.removeAll()
        for workoutID in likes.keys { likes[workoutID]?[me] = nil }
        handleRegistry = handleRegistry.filter { $0.value != me }
        profiles[me] = nil
    }

    // MARK: - Seeding (demo/preview only)

    /// Directly inserts another user's profile + shared workouts and makes the
    /// local user follow them — for previews and simulator demos.
    public func seed(profile: SocialProfile, workouts: [(dto: SharedWorkoutDTO, summary: SharedWorkoutSummary, publishedAt: Date)], follow: Bool) {
        profiles[profile.userID] = profile
        handleRegistry[SocialHandle.normalize(profile.handle)] = profile.userID
        var list: [SocialWorkoutRef] = []
        for w in workouts {
            payloads[w.dto.id] = w.dto
            list.append(SocialWorkoutRef(id: w.dto.id, owner: profile.userID, title: w.dto.title, startedAt: w.dto.startedAt, publishedAt: w.publishedAt, summary: w.summary))
        }
        refs[profile.userID] = list.sorted { $0.publishedAt > $1.publishedAt }
        if follow { follows.insert(profile.userID) }
    }

    /// Plants another user's heart on a workout — demo/preview only. The
    /// production path only ever likes as `me` (CloudKit enforces the same:
    /// you can't write a like record naming someone else's user ID).
    public func seedLike(workoutID: UUID, by user: SocialUserID, at date: Date) {
        likes[workoutID, default: [:]][user] = date
    }
}

extension SocialProfile {
    /// Reads the rankable value for a metric — the mock's client-side ranking.
    /// The CloudKit backend queries the corresponding record field instead.
    func value(for metric: SocialLeaderboardMetric) -> Double {
        switch metric {
        case .totalVolume: stats.lifetimeVolumeKg
        case .bestE1RM: stats.bestE1RMKg
        case .cardioDistance: stats.cardioDistanceMeters
        case .cardioMinutes: stats.cardioMinutes
        case .yogaMinutes: stats.yogaMinutes
        case .xp: Double(totalXP)
        }
    }
}
