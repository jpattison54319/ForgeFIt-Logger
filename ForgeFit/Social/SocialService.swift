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
    private struct BootstrapOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

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
    private var bootstrapOperation: BootstrapOperation?
    private var cancelledBootstrapTask: Task<Void, Never>?
    private var bootstrapResumeTask: Task<Void, Never>?
    private var isLiveWorkoutActive = false
    private var bootstrapPendingAfterWorkout = false
    private let defaults: UserDefaults
    private var reconcileInFlight = false
    private var drainInFlight = false
    private var lastCleanReconcileAt: Date?

    /// Whether Community is switched on for this build. Injected rather than
    /// read from `FeatureFlags` inside the service so tests can exercise the
    /// social logic without touching global defaults — the app decides in
    /// `make()`, which is the only composition root.
    let isEnabled: Bool

    init(
        backend: SocialBackend,
        isDemo: Bool,
        isEnabled: Bool = true,
        defaults: UserDefaults = .standard
    ) {
        self.backend = backend
        self.isDemo = isDemo
        self.isEnabled = isEnabled
        self.defaults = defaults
    }

    /// Chooses the backend. The mock is seeded lazily in `bootstrap()`.
    ///
    /// With Community off the CloudKit backend is never constructed. That is
    /// not just tidiness: `CKContainer(identifier:)` traps when the process
    /// lacks the `com.apple.developer.icloud-services` entitlement, so building
    /// it for a feature nobody can reach is a crash waiting for a build without
    /// full entitlements. The inert mock keeps the environment object's shape
    /// while `isEnabled == false` stops anything from calling it.
    static func make() -> SocialService {
        let isEnabled = FeatureFlags.social
        if !isEnabled || ProcessInfo.processInfo.arguments.contains("--mock-social") {
            return SocialService(
                backend: MockSocialBackend(me: SocialUserID("demo-me")),
                isDemo: isEnabled,
                isEnabled: isEnabled
            )
        }
        return SocialService(
            backend: CloudKitSocialBackend(),
            isDemo: false,
            isEnabled: isEnabled
        )
    }

    /// The single gate every publish, reconcile, and hearts path checks. With
    /// Community off it stays false, so nothing reaches CloudKit even if a
    /// profile were somehow present locally.
    var isOptedIn: Bool { isEnabled && myProfile != nil }

    func setLiveWorkoutActive(_ isActive: Bool) {
        guard isLiveWorkoutActive != isActive else { return }
        isLiveWorkoutActive = isActive
        if isActive {
            bootstrapPendingAfterWorkout = bootstrapPendingAfterWorkout || !didBootstrap
            if let task = bootstrapOperation?.task {
                cancelledBootstrapTask = task
                task.cancel()
            }
            bootstrapOperation = nil
            bootstrapResumeTask?.cancel()
            bootstrapResumeTask = nil
        } else if bootstrapPendingAfterWorkout, !didBootstrap {
            bootstrapResumeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if let cancelledBootstrapTask {
                    await cancelledBootstrapTask.value
                    self.cancelledBootstrapTask = nil
                }
                guard !Task.isCancelled, !isLiveWorkoutActive else { return }
                await bootstrap()
                guard !Task.isCancelled, !isLiveWorkoutActive else { return }
                bootstrapResumeTask = nil
            }
        }
    }

    func bootstrap() async {
        guard isEnabled else { return }
        guard !isLiveWorkoutActive else {
            bootstrapPendingAfterWorkout = true
            return
        }
        guard !didBootstrap else { return }
        if let bootstrapOperation {
            await bootstrapOperation.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performBootstrap()
        }
        bootstrapOperation = BootstrapOperation(id: id, task: task)
        await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        if bootstrapOperation?.id == id {
            bootstrapOperation = nil
        }
    }

    private func performBootstrap() async {
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            bootstrapPendingAfterWorkout = true
            return
        }
        if isDemo, let mock = backend as? MockSocialBackend {
            await SocialDemoData.seed(into: mock)
            guard !isLiveWorkoutActive, !Task.isCancelled else {
                bootstrapPendingAfterWorkout = true
                return
            }
            #if DEBUG
            // `--seed-social-hearts` implies an opted-in demo user: hearts
            // only exist on published workouts, and publishing requires a
            // profile. Without this the flag would silently do nothing.
            if ProcessInfo.processInfo.arguments.contains("--seed-social-hearts") {
                await SocialDemoData.seedMyProfile(into: mock)
                guard !isLiveWorkoutActive, !Task.isCancelled else {
                    bootstrapPendingAfterWorkout = true
                    return
                }
            }
            #endif
        }
        await refresh()
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            bootstrapPendingAfterWorkout = true
            return
        }
        #if DEBUG
        // Dev builds keep the Development environment's schema complete so a
        // dashboard deploy always carries every record type — see
        // SocialSchemaPrimer for why Follow/Like can't self-create.
        await SocialSchemaPrimer.primeIfNeeded(using: backend)
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            bootstrapPendingAfterWorkout = true
            return
        }
        #endif
        didBootstrap = true
        bootstrapPendingAfterWorkout = false
    }

    func refresh() async {
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            bootstrapPendingAfterWorkout = bootstrapPendingAfterWorkout || !didBootstrap
            return
        }
        do {
            let id = try await backend.currentUserID()
            guard !isLiveWorkoutActive, !Task.isCancelled else {
                bootstrapPendingAfterWorkout = bootstrapPendingAfterWorkout || !didBootstrap
                return
            }
            myUserID = id
            let profile = try await backend.profile(for: id)
            guard !isLiveWorkoutActive, !Task.isCancelled else {
                bootstrapPendingAfterWorkout = bootstrapPendingAfterWorkout || !didBootstrap
                return
            }
            myProfile = profile
            status = myProfile == nil ? .notOptedIn : .active
        } catch {
            guard !isLiveWorkoutActive, !Task.isCancelled else {
                bootstrapPendingAfterWorkout = bootstrapPendingAfterWorkout || !didBootstrap
                return
            }
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
        // Fresh profile, empty remote: intents queued against any previous
        // account have nothing left to act on.
        defaults.removeObject(forKey: Self.shareOutboxKey)
        defaults.removeObject(forKey: Self.legacyPendingUnpublishKey)
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

    /// Permanently removes the user's community presence — profile, handle,
    /// every shared workout, follows, and likes. Throws on failure without
    /// touching local state: the backend deletes the profile record last, so
    /// a partial failure leaves the account visibly opted-in and the deletion
    /// UI reachable for a retry. On success the hub falls back to the
    /// opt-in gate.
    func deleteProfile() async throws {
        try await backend.deleteAllMyData()
        clearDeletedProfileState()
    }

    /// Deletes public data left by an earlier Community-enabled build while
    /// keeping the disabled feature from contacting CloudKit at launch. The
    /// production backend is constructed only after the user selects the
    /// explicit deletion action in Settings.
    func deleteLegacyProfile() async throws {
        try await CloudKitSocialBackend().deleteAllMyData()
        clearDeletedProfileState()
    }

    private func clearDeletedProfileState() {
        myProfile = nil
        status = .notOptedIn
        // The wipe removed every shared workout — nothing left to act on.
        defaults.removeObject(forKey: Self.shareOutboxKey)
        defaults.removeObject(forKey: Self.legacyPendingUnpublishKey)
    }

    // MARK: Share outbox

    /// Durable queue of share intents keyed by workout id — the write side of
    /// the sync pipeline. `SyncCoordinator` derives intents from SwiftData
    /// save notifications (finish → publish, edit → publish, delete →
    /// unpublish) and enqueues them here; entries survive relaunches, so an
    /// intent recorded offline still executes when connectivity returns.
    /// Everything downstream is an idempotent upsert/delete by id, so
    /// duplicate drains are harmless.
    enum ShareOp: String {
        case publish
        case unpublish
    }

    static let shareOutboxKey = "socialShareOutbox.v1"
    /// Pre-outbox tombstone store (unpublish-only); migrated on first read.
    static let legacyPendingUnpublishKey = "socialPendingUnpublish.v1"
    /// Remote page size while walking the full ref set (summaries only).
    static let reconcilePageSize = 200
    /// Foreground reconciles are throttled; launch and opt-in pass `force`.
    private static let reconcileThrottle: TimeInterval = 10 * 60

    private var shareOutbox: [UUID: ShareOp] {
        get {
            var entries: [UUID: ShareOp] = [:]
            for (key, raw) in defaults.dictionary(forKey: Self.shareOutboxKey) as? [String: String] ?? [:] {
                if let id = UUID(uuidString: key), let op = ShareOp(rawValue: raw) { entries[id] = op }
            }
            // One-time migration of the old unpublish tombstones.
            if let legacy = defaults.stringArray(forKey: Self.legacyPendingUnpublishKey) {
                for id in legacy.compactMap(UUID.init) { entries[id] = .unpublish }
                defaults.removeObject(forKey: Self.legacyPendingUnpublishKey)
                persistOutbox(entries)
            }
            return entries
        }
        set { persistOutbox(newValue) }
    }

    private func persistOutbox(_ entries: [UUID: ShareOp]) {
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.shareOutboxKey)
        } else {
            defaults.set(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value.rawValue) }), forKey: Self.shareOutboxKey)
        }
    }

    /// Records intents. Unpublish is terminal — it overwrites a queued
    /// publish for the same workout, and a later publish never resurrects a
    /// queued unpublish (deleted stays deleted).
    func enqueueShare(_ ops: [UUID: ShareOp]) {
        guard isOptedIn, !ops.isEmpty else { return }
        var outbox = shareOutbox
        for (id, op) in ops where outbox[id] != .unpublish {
            outbox[id] = op
        }
        shareOutbox = outbox
    }

    /// Executes every queued intent. Publish entries whose workout the
    /// builder no longer yields (deleted meanwhile, emptied, ineligible) are
    /// dropped — the delete path enqueues its own unpublish. Failures stay
    /// queued for the next drain (foreground, connectivity, reconcile).
    func drainShareOutbox(makeItems: (Set<UUID>) -> [SocialBackfillItem]) async {
        guard isOptedIn, !drainInFlight, !Task.isCancelled else { return }
        let outbox = shareOutbox
        guard !outbox.isEmpty else { return }
        drainInFlight = true
        defer { drainInFlight = false }

        let publishIDs = Set(outbox.filter { $0.value == .publish }.map(\.key))
        var built: [UUID: SocialBackfillItem] = [:]
        if !publishIDs.isEmpty {
            for item in makeItems(publishIDs) { built[item.dto.id] = item }
        }

        var remaining = outbox
        for (id, op) in outbox {
            guard !Task.isCancelled else { break }
            switch op {
            case .publish:
                guard let item = built[id] else {
                    remaining.removeValue(forKey: id)
                    continue
                }
                do {
                    try await backend.publishWorkout(item.dto, summary: item.summary, publishedAt: item.publishedAt, sourceUpdatedAt: item.sourceUpdatedAt)
                    remaining.removeValue(forKey: id)
                } catch { }
            case .unpublish:
                do {
                    try await backend.unpublishWorkout(id: id)
                    remaining.removeValue(forKey: id)
                } catch { }
            }
        }
        shareOutbox = remaining
    }

    /// Anti-entropy backstop: converges the backend to the local training
    /// log even if an outbox intent was ever lost (crash inside the debounce
    /// window, missed save event, pre-outbox install). One mechanism covers
    /// the initial enable-social backfill (empty remote), accounts opted in
    /// before backfill existed, offline finishes, offline deletes, and edits
    /// to already-shared workouts.
    ///
    /// The caller owns the training data: it passes id + `updatedAt` stamps
    /// for every eligible workout plus the locally-deleted ids, and builds
    /// DTOs only for the workouts that actually need publishing
    /// (`makeItems`), so a settled steady state costs one id/watermark diff
    /// and no mapping.
    ///
    /// Publish set = missing remotely ∪ drifted (local `updatedAt` newer
    /// than the remote `sourceUpdatedAt` watermark — republishing keeps
    /// `publishedAt`, so edited workouts refresh in place without jumping
    /// the profile order).
    ///
    /// Safety rule: a workout is only unpublished on local *evidence of
    /// deletion* — a queued unpublish intent or a `deletedAt`-stamped row.
    /// Remote workouts simply absent from this device's store are left
    /// alone, so a fresh install (workouts are a local-only store) can never
    /// wipe a profile.
    func reconcileSharedWorkouts(
        eligible: [SocialShareStamp],
        deletedIDs: Set<UUID>,
        force: Bool = false,
        makeItems: (Set<UUID>) -> [SocialBackfillItem]
    ) async {
        guard isOptedIn, let myUserID, !reconcileInFlight,
              !Task.isCancelled else { return }
        if !force, let last = lastCleanReconcileAt,
           Date().timeIntervalSince(last) < Self.reconcileThrottle { return }
        reconcileInFlight = true
        defer { reconcileInFlight = false }

        // The complete remote picture (id + watermark), walked page by page.
        // Any fetch error aborts the pass: acting on a partial remote picture
        // would republish workouts that are already there.
        var remoteWatermarks: [UUID: Date] = [:]
        var cursor: Date?
        while true {
            guard !Task.isCancelled else { return }
            let page: [SocialWorkoutRef]
            do {
                page = try await backend.recentWorkouts(for: myUserID, limit: Self.reconcilePageSize, before: cursor)
            } catch {
                return
            }
            for ref in page {
                guard !Task.isCancelled else { return }
                // Pre-watermark records read as infinitely stale and self-heal.
                remoteWatermarks[ref.id] = ref.sourceUpdatedAt ?? .distantPast
            }
            guard page.count == Self.reconcilePageSize, let last = page.last else { break }
            cursor = last.publishedAt
        }

        var toPublish = Set<UUID>()
        for stamp in eligible {
            guard !Task.isCancelled else { return }
            guard let watermark = remoteWatermarks[stamp.id] else {
                toPublish.insert(stamp.id)   // missing remotely
                continue
            }
            // 1s slack absorbs the date round-trip through the record store.
            if stamp.updatedAt.timeIntervalSince(watermark) > 1 {
                toPublish.insert(stamp.id)   // edited since last shared
            }
        }

        var clean = true
        if !toPublish.isEmpty {
            for item in makeItems(toPublish) {
                guard !Task.isCancelled else { return }
                do {
                    try await backend.publishWorkout(item.dto, summary: item.summary, publishedAt: item.publishedAt, sourceUpdatedAt: item.sourceUpdatedAt)
                } catch {
                    clean = false
                }
            }
        }

        let stale = Set(remoteWatermarks.keys).intersection(deletedIDs)
        for id in stale {
            guard !Task.isCancelled else { return }
            do {
                try await backend.unpublishWorkout(id: id)
            } catch {
                clean = false
            }
        }

        // Only a fully clean pass arms the throttle — a pass with failures
        // retries on the next trigger instead of waiting it out.
        if clean, !Task.isCancelled { lastCleanReconcileAt = Date() }
    }

    // MARK: Pass-throughs the UI uses

    func profile(for id: SocialUserID) async -> SocialProfile? { try? await backend.profile(for: id) }
    func lookup(handle: String) async -> SocialProfile? { try? await backend.profile(forHandle: handle) }
    func recentWorkouts(for id: SocialUserID, limit: Int = 20, before: Date? = nil) async -> [SocialWorkoutRef] {
        (try? await backend.recentWorkouts(for: id, limit: limit, before: before)) ?? []
    }
    func workoutDetail(id: UUID) async -> SharedWorkoutDTO? { try? await backend.workoutDetail(id: id) }

    /// Throwing on purpose: the profile button reflects backend truth, so a
    /// failed write must reach the UI. Swallowing errors here produced the
    /// "Following → gone → Follow again" loop when the server rejected the
    /// record — the tap looked successful and nothing ever persisted.
    func follow(_ id: SocialUserID) async throws { try await backend.follow(id) }
    func unfollow(_ id: SocialUserID) async throws { try await backend.unfollow(id) }
    func isFollowing(_ id: SocialUserID) async -> Bool { (try? await backend.isFollowing(id)) ?? false }
    func following() async -> [SocialUserID] { (try? await backend.following()) ?? [] }

    func setLike(_ liked: Bool, workoutID: UUID) async { try? await backend.setLike(liked, workoutID: workoutID) }
    func likeCount(workoutID: UUID) async -> Int { (try? await backend.likeCount(workoutID: workoutID)) ?? 0 }
    func hasLiked(workoutID: UUID) async -> Bool { (try? await backend.hasLiked(workoutID: workoutID)) ?? false }

    // MARK: Hearts (own workout history)

    /// A workout's hearts with the lead liker resolved for the history row.
    /// Ephemeral by design — hearts are third-party social data and must
    /// never be cached into a SwiftData model (CloudKit-shaped models sync
    /// to the private DB, which carries only the user's own training plan).
    struct WorkoutHearts {
        let likes: [SocialLike]
        /// Display name of the most recent liker; "You" for your own heart;
        /// nil when their profile is gone (deleted account).
        let leadName: String?
        var count: Int { likes.count }
    }

    private struct HeartsCacheEntry { let hearts: WorkoutHearts; let fetchedAt: Date }
    private var heartsCache: [UUID: HeartsCacheEntry] = [:]
    private var likerProfileCache: [SocialUserID: SocialProfile?] = [:]
    private static let heartsCacheTTL: TimeInterval = 60

    /// Errors surface as nil; an empty successful response remains a concrete
    /// zero-like result so the history UI can distinguish it from unavailable.
    func hearts(workoutID: UUID) async -> WorkoutHearts? {
        if let cached = heartsCache[workoutID], Date().timeIntervalSince(cached.fetchedAt) < Self.heartsCacheTTL {
            return cached.hearts
        }
        guard let likes = try? await backend.likers(workoutID: workoutID) else { return nil }
        // Only the lead liker resolves here — the full list resolves lazily
        // in the sheet, so the row costs one profile fetch, not N.
        var leadName: String?
        if let lead = likes.first {
            leadName = lead.userID == myUserID ? "You" : await likerProfile(for: lead.userID)?.displayName
        }
        let hearts = WorkoutHearts(likes: likes, leadName: leadName)
        heartsCache[workoutID] = HeartsCacheEntry(hearts: hearts, fetchedAt: Date())
        return hearts
    }

    /// Profile lookup memoized for the hearts UI — nil results (deleted
    /// profiles) cache too, so a gone liker doesn't re-query every row.
    func likerProfile(for id: SocialUserID) async -> SocialProfile? {
        if let cached = likerProfileCache[id] { return cached }
        let profile = try? await backend.profile(for: id)
        likerProfileCache[id] = .some(profile)
        return profile
    }

    /// `--seed-social-hearts` (mock only): plants seeded friends' hearts on
    /// the given workouts so the simulator renders the hearts row without
    /// having to finish a live workout first. Deliberately a SEPARATE arg
    /// from `--mock-social` — every sim launch needs the mock, and
    /// automation that screenshots workout detail must not grow an
    /// unexpected hearts row.
    func seedDemoHearts(workoutIDs: [UUID]) async {
        #if DEBUG
        guard isDemo,
              ProcessInfo.processInfo.arguments.contains("--seed-social-hearts"),
              let mock = backend as? MockSocialBackend else { return }
        let friends = ["friend-mia", "friend-alex", "friend-sam"]
        for (workoutIndex, workoutID) in workoutIDs.enumerated() {
            // Vary the count so the row shows both the single-heart and
            // overflow ("+2") presentations across a seeded history.
            let heartCount = (workoutIndex % 3) + 1
            for friendIndex in 0..<heartCount {
                await mock.seedLike(
                    workoutID: workoutID,
                    by: SocialUserID(friends[friendIndex]),
                    at: Date().addingTimeInterval(TimeInterval(-friendIndex * 3600 - workoutIndex * 60))
                )
            }
            heartsCache[workoutID] = nil
        }
        #endif
    }

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
