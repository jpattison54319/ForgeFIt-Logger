#if DEBUG
import ForgeData
import Foundation
import OSLog

/// Dev-environment CloudKit schema priming.
///
/// CloudKit's Development environment creates record types just-in-time when
/// a record is first SAVED — schema comes from records written, not from code
/// existing. Profile, handle-claim, and shared-workout types appear the
/// moment one dev user opts in and trains, but `Follow` and `Like` need a
/// *second person* to exercise, so a single-developer environment never
/// creates them — and "Deploy Schema Changes" then ships a production schema
/// without them (the field bug: follows silently rejected in TestFlight).
///
/// This writes one throwaway record of each such type against fabricated ids,
/// verifies both direct reads and the indexed queries the app actually uses,
/// and deletes the records immediately. The data is gone; the Development
/// schema stays. After a successful run, deploy Development → Production in
/// the CloudKit Dashboard. `Like.likerID` is used only by account deletion, so
/// that index remains a dashboard check rather than a destructive primer step.
///
/// DEBUG-only and gated to the real CloudKit backend: release builds talk to
/// production (never prime it), and the mock needs no schema.
enum SocialSchemaPrimer {
    static let version = 2
    static let versionKey = "socialSchemaPrimedVersion"
    static let lastErrorKey = "socialSchemaPrimerLastError"
    static let lastSuccessKey = "socialSchemaPrimerLastSuccess"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.xpetsllc.ForgeFit",
        category: "SocialSchemaPrimer"
    )

    private enum ValidationError: LocalizedError {
        case followDirectRead
        case followQuery
        case likeDirectRead
        case likeQuery

        var errorDescription: String? {
            switch self {
            case .followDirectRead: "Follow save could not be read back by record ID."
            case .followQuery: "Follow.followerID query did not return the saved record."
            case .likeDirectRead: "Like save could not be read back by record ID."
            case .likeQuery: "Like.workoutID query did not return the saved record."
            }
        }
    }

    static func primeIfNeeded(using backend: SocialBackend) async {
        guard backend is CloudKitSocialBackend else { return }
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: versionKey) < version else { return }

        let ghost = SocialUserID("schema-primer-ghost-v2")
        let ghostWorkoutID = UUID(uuidString: "00000000-0000-0000-0000-0000000FEED6")!
        var followNeedsCleanup = false
        var likeNeedsCleanup = false

        do {
            // Make a retry safe if a previous launch was interrupted between
            // save and cleanup.
            try? await backend.unfollow(ghost)
            try? await backend.setLike(false, workoutID: ghostWorkoutID)

            try await backend.follow(ghost)
            followNeedsCleanup = true
            guard try await backend.isFollowing(ghost) else {
                throw ValidationError.followDirectRead
            }
            guard try await eventually({
                try await backend.following().contains(ghost)
            }) else {
                throw ValidationError.followQuery
            }
            try await backend.unfollow(ghost)
            followNeedsCleanup = false

            try await backend.setLike(true, workoutID: ghostWorkoutID)
            likeNeedsCleanup = true
            guard try await backend.hasLiked(workoutID: ghostWorkoutID) else {
                throw ValidationError.likeDirectRead
            }
            guard try await eventually({
                try await backend.likeCount(workoutID: ghostWorkoutID) > 0
            }) else {
                throw ValidationError.likeQuery
            }
            try await backend.setLike(false, workoutID: ghostWorkoutID)
            likeNeedsCleanup = false

            defaults.removeObject(forKey: lastErrorKey)
            defaults.set(Date(), forKey: lastSuccessKey)
            defaults.set(version, forKey: versionKey)
            logger.notice("Development social schema verification succeeded (version \(version)).")
        } catch {
            if likeNeedsCleanup {
                try? await backend.setLike(false, workoutID: ghostWorkoutID)
            }
            if followNeedsCleanup {
                try? await backend.unfollow(ghost)
            }

            let message = error.localizedDescription
            defaults.set(message, forKey: lastErrorKey)
            logger.error("Development social schema verification failed: \(message, privacy: .public)")
            // Leave the version flag unset so the next dev launch retries.
        }
    }

    /// Public-database queries are eventually consistent even when fetching
    /// the saved record directly already succeeds. Give the DEBUG verifier a
    /// short bounded retry window so it tests the index without treating that
    /// normal propagation delay as a schema failure.
    private static func eventually(
        attempts: Int = 6,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        for attempt in 0..<attempts {
            if try await condition() { return true }
            if attempt < attempts - 1 {
                try await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }
}
#endif
