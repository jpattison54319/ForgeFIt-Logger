import Foundation

/// Opaque, stable per-user identity. Backed by the CloudKit user record name
/// (`__defaultOwner` resolves to a per-app-per-user recordID). The follow graph
/// and all ownership are keyed on THIS, never on the mutable handle — so a user
/// renaming their handle never breaks relationships.
public struct SocialUserID: Codable, Hashable, Sendable {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Who may follow a user once they've opted into Social.
public enum SocialVisibility: String, Codable, Sendable, CaseIterable {
    /// Discoverable; anyone can follow and view (public account).
    case everyone
    /// Not in global discovery; follows require approval (private account).
    case approveFollowers
}

/// A user's public profile — the "visit their profile" payload and the row
/// behind every leaderboard entry. Carries only shareable, non-health data:
/// a handle/name, gamification (XP/level derive from `totalXP`), and training
/// aggregates. No heart rate, sleep, readiness, or body weight.
public struct SocialProfile: Codable, Sendable, Equatable {
    public var userID: SocialUserID
    /// Unique, lowercased discovery key (claimed via a handle-registry record).
    public var handle: String
    /// Free-text display name (UGC — subject to moderation).
    public var displayName: String
    public var totalXP: Int
    public var workoutCount: Int
    public var lifetimeHours: Double
    public var stats: SocialStats
    public var visibility: SocialVisibility
    /// Appears in global discovery/search. Independent of `visibility` so a user
    /// can be followable-by-link without being globally searchable.
    public var discoverable: Bool
    public var updatedAt: Date

    public init(
        userID: SocialUserID,
        handle: String,
        displayName: String,
        totalXP: Int = 0,
        workoutCount: Int = 0,
        lifetimeHours: Double = 0,
        stats: SocialStats = SocialStats(),
        visibility: SocialVisibility = .everyone,
        discoverable: Bool = true,
        updatedAt: Date
    ) {
        self.userID = userID
        self.handle = handle
        self.displayName = displayName
        self.totalXP = totalXP
        self.workoutCount = workoutCount
        self.lifetimeHours = lifetimeHours
        self.stats = stats
        self.visibility = visibility
        self.discoverable = discoverable
        self.updatedAt = updatedAt
    }
}

/// Precomputed leaderboard aggregates, published with the profile and updated
/// on workout finish. Numbers only — nothing health-derived. Ranking a global
/// leaderboard is a public query sorted by one of these fields.
public struct SocialStats: Codable, Sendable, Equatable {
    public var lifetimeVolumeKg: Double
    public var bestE1RMKg: Double
    public var cardioDistanceMeters: Double
    public var cardioMinutes: Double
    public var yogaMinutes: Double

    public init(
        lifetimeVolumeKg: Double = 0,
        bestE1RMKg: Double = 0,
        cardioDistanceMeters: Double = 0,
        cardioMinutes: Double = 0,
        yogaMinutes: Double = 0
    ) {
        self.lifetimeVolumeKg = lifetimeVolumeKg
        self.bestE1RMKg = bestE1RMKg
        self.cardioDistanceMeters = cardioDistanceMeters
        self.cardioMinutes = cardioMinutes
        self.yogaMinutes = yogaMinutes
    }
}

/// A lightweight reference to a shared workout — enough to render a
/// recent-workouts row without decoding the full payload. Mirrors the queryable
/// fields on the CloudKit `SharedWorkout` record.
public struct SocialWorkoutRef: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var owner: SocialUserID
    public var title: String?
    public var startedAt: Date
    /// Publish time — the ordering key for "recent workouts".
    public var publishedAt: Date
    public var summary: SharedWorkoutSummary

    public init(
        id: UUID,
        owner: SocialUserID,
        title: String?,
        startedAt: Date,
        publishedAt: Date,
        summary: SharedWorkoutSummary
    ) {
        self.id = id
        self.owner = owner
        self.title = title
        self.startedAt = startedAt
        self.publishedAt = publishedAt
        self.summary = summary
    }
}

/// A rankable metric, grouped by training category.
public enum SocialLeaderboardMetric: String, Codable, Sendable, CaseIterable, Hashable {
    case totalVolume       // strength
    case bestE1RM          // strength
    case cardioDistance    // cardio
    case cardioMinutes     // cardio
    case yogaMinutes       // yoga
    case xp                // overall

    public enum Category: String, Sendable { case strength, cardio, yoga, overall }

    public var category: Category {
        switch self {
        case .totalVolume, .bestE1RM: .strength
        case .cardioDistance, .cardioMinutes: .cardio
        case .yogaMinutes: .yoga
        case .xp: .overall
        }
    }
}

public enum LeaderboardScope: Sendable, Hashable { case friends, global }

public struct SocialLeaderboardEntry: Sendable, Equatable, Identifiable {
    public var profile: SocialProfile
    public var value: Double
    public var rank: Int
    public var id: String { profile.userID.rawValue }

    public init(profile: SocialProfile, value: Double, rank: Int) {
        self.profile = profile
        self.value = value
        self.rank = rank
    }
}

public enum SocialError: Error, Sendable, Equatable {
    /// A different user already owns this handle.
    case handleTaken
    case notFound
    /// The action requires the local user to have opted into Social first.
    case notOptedIn
    case invalidHandle
}
