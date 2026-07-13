import ForgeData
import Foundation
import SwiftUI

/// The app-facing social layer. Owns identity + the local user's opt-in state,
/// and forwards everything else to a `SocialBackend`. The UI depends only on
/// this object, so the whole feature runs against `MockSocialBackend` in the
/// simulator (launch with `--mock-social`) and against CloudKit on device.
@MainActor
@Observable
final class SocialService {
    enum Status: Equatable {
        case loading
        /// Backend reachable, but the user hasn't created a public profile yet.
        case notOptedIn
        /// Opted in — `myProfile` is populated.
        case active
        /// Couldn't resolve identity (no iCloud account, offline). Message shown.
        case unavailable(String)
    }

    let backend: SocialBackend
    /// True for the seeded in-memory backend — surfaces a "demo" chip in the UI.
    let isDemo: Bool

    private(set) var status: Status = .loading
    private(set) var myUserID: SocialUserID?
    private(set) var myProfile: SocialProfile?
    /// Set when a `forgefit://u/<handle>` link is opened; the hub consumes it.
    var pendingFollowHandle: String?

    private var didBootstrap = false

    init(backend: SocialBackend, isDemo: Bool) {
        self.backend = backend
        self.isDemo = isDemo
    }

    /// Chooses the backend. The mock is seeded lazily in `bootstrap()`.
    static func make() -> SocialService {
        if ProcessInfo.processInfo.arguments.contains("--mock-social") {
            return SocialService(backend: MockSocialBackend(me: SocialUserID("demo-me")), isDemo: true)
        }
        return SocialService(backend: CloudKitSocialBackend(), isDemo: false)
    }

    var isOptedIn: Bool { myProfile != nil }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        if isDemo, let mock = backend as? MockSocialBackend {
            await SocialDemoData.seed(into: mock)
        }
        await refresh()
    }

    func refresh() async {
        do {
            let id = try await backend.currentUserID()
            myUserID = id
            myProfile = try await backend.profile(for: id)
            status = myProfile == nil ? .notOptedIn : .active
        } catch {
            status = .unavailable("Sign in to iCloud in Settings to use ForgeFit social.")
        }
    }

    // MARK: Opt-in / profile

    /// Claims the handle and publishes the initial profile. Throws
    /// `SocialError.handleTaken` if the handle is already owned by someone else.
    func optIn(handle: String, displayName: String, visibility: SocialVisibility, stats: ProfileSnapshot) async throws {
        guard try await backend.claimHandle(handle) else { throw SocialError.handleTaken }
        let id: SocialUserID
        if let myUserID {
            id = myUserID
        } else if let resolved = try? await backend.currentUserID() {
            id = resolved
        } else {
            throw SocialError.notOptedIn
        }
        myUserID = id
        let profile = SocialProfile(
            userID: id,
            handle: SocialHandle.normalize(handle),
            displayName: displayName,
            totalXP: stats.totalXP,
            workoutCount: stats.workoutCount,
            lifetimeHours: stats.lifetimeHours,
            stats: stats.stats,
            visibility: visibility,
            discoverable: visibility == .everyone,
            updatedAt: stats.now
        )
        try await backend.upsertMyProfile(profile)
        myProfile = profile
        status = .active
    }

    /// Refreshes the published profile's aggregates + display fields. No-op if
    /// not opted in.
    func syncMyProfile(_ snapshot: ProfileSnapshot, displayName: String) async {
        guard var profile = myProfile else { return }
        profile.displayName = displayName
        profile.totalXP = snapshot.totalXP
        profile.workoutCount = snapshot.workoutCount
        profile.lifetimeHours = snapshot.lifetimeHours
        profile.stats = snapshot.stats
        profile.updatedAt = snapshot.now
        try? await backend.upsertMyProfile(profile)
        myProfile = profile
    }

    func setVisibility(_ visibility: SocialVisibility) async {
        guard var profile = myProfile else { return }
        profile.visibility = visibility
        profile.discoverable = visibility == .everyone
        profile.updatedAt = Date()
        try? await backend.upsertMyProfile(profile)
        myProfile = profile
    }

    // MARK: Publish

    func publish(_ dto: SharedWorkoutDTO, summary: SharedWorkoutSummary) async {
        guard isOptedIn else { return }
        try? await backend.publishWorkout(dto, summary: summary, publishedAt: Date())
    }

    func unpublish(id: UUID) async { try? await backend.unpublishWorkout(id: id) }

    // MARK: Pass-throughs the UI uses

    func profile(for id: SocialUserID) async -> SocialProfile? { try? await backend.profile(for: id) }
    func lookup(handle: String) async -> SocialProfile? { try? await backend.profile(forHandle: handle) }
    func recentWorkouts(for id: SocialUserID, limit: Int = 20) async -> [SocialWorkoutRef] {
        (try? await backend.recentWorkouts(for: id, limit: limit)) ?? []
    }
    func workoutDetail(id: UUID) async -> SharedWorkoutDTO? { try? await backend.workoutDetail(id: id) }

    func follow(_ id: SocialUserID) async { try? await backend.follow(id) }
    func unfollow(_ id: SocialUserID) async { try? await backend.unfollow(id) }
    func isFollowing(_ id: SocialUserID) async -> Bool { (try? await backend.isFollowing(id)) ?? false }
    func following() async -> [SocialUserID] { (try? await backend.following()) ?? [] }

    func setLike(_ liked: Bool, workoutID: UUID) async { try? await backend.setLike(liked, workoutID: workoutID) }
    func likeCount(workoutID: UUID) async -> Int { (try? await backend.likeCount(workoutID: workoutID)) ?? 0 }
    func hasLiked(workoutID: UUID) async -> Bool { (try? await backend.hasLiked(workoutID: workoutID)) ?? false }

    func leaderboard(metric: SocialLeaderboardMetric, scope: LeaderboardScope, limit: Int = 50) async -> [SocialLeaderboardEntry] {
        (try? await backend.leaderboard(metric: metric, scope: scope, limit: limit)) ?? []
    }
}

/// A local snapshot of the user's shareable aggregates, computed from the
/// on-device training log (never health data). Feeds opt-in and profile sync.
struct ProfileSnapshot {
    var totalXP: Int
    var workoutCount: Int
    var lifetimeHours: Double
    var stats: SocialStats
    var now: Date
}
