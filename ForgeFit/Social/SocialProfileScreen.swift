import ForgeData
import SwiftUI

/// Another athlete's profile — their stats + level (mirroring your own Profile
/// screen) and their recent shared workouts. Also used to preview your own
/// public profile.
struct SocialProfileScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social
    let userID: SocialUserID
    var preloaded: SocialProfile?

    @State private var profile: SocialProfile?
    @State private var recent: [SocialWorkoutRef] = []
    @State private var isFollowing = false
    @State private var loaded = false
    @State private var busy = false
    @State private var followError: String?

    /// Small first fetch — the profile answers "what have they been up to";
    /// full history lives behind "View all workouts".
    private static let previewLimit = 6

    private var isSelf: Bool { social.myUserID == userID }

    var body: some View {
        DashboardScaffold(title: profile?.displayName ?? "Profile", dismiss: dismiss) {
            if let profile {
                SocialProfileHeaderView(profile: profile)
                if !isSelf { followButton }
                if let followError {
                    Text(followError)
                        .font(.system(size: 13)).foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("social-follow-error")
                }

                SectionHeader("Recent workouts")
                if recent.isEmpty {
                    EmptyStateCard(title: "No shared workouts", message: "When \(profile.displayName) logs a workout, it shows up here.", systemImage: "dumbbell")
                } else {
                    ForEach(recent) { ref in
                        NavigationLink { SharedWorkoutDetailView(ref: ref, ownerName: profile.displayName) } label: {
                            SocialWorkoutRow(ref: ref)
                        }
                        .buttonStyle(.plain)
                    }
                    // A full preview page means there may be more history —
                    // the paginated list takes over from here, keeping this
                    // screen a cheap single small fetch.
                    if recent.count == Self.previewLimit {
                        NavigationLink {
                            SharedWorkoutsListView(userID: userID, ownerName: profile.displayName)
                        } label: {
                            Card(padding: Space.md) {
                                HStack(spacing: Space.md) {
                                    Image(systemName: "calendar").font(.system(size: 16)).foregroundStyle(theme.accent).frame(width: 28)
                                    Text("View all workouts").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("social-view-all-workouts")
                    }
                }
            } else if loaded {
                EmptyStateCard(title: "Profile unavailable", message: "This athlete isn't on ForgeFit social, or their profile is private.", systemImage: "person.slash")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xl)
            }
        }
        .task(id: userID) { await load() }
    }

    private var followButton: some View {
        Group {
            if isFollowing {
                SecondaryButton(title: "Following", systemImage: "checkmark") { Task { await toggleFollow() } }
            } else {
                PrimaryButton(title: "Follow", systemImage: "person.badge.plus") { Task { await toggleFollow() } }
            }
        }
        .disabled(busy)
    }

    private func load() async {
        if let preloaded { profile = preloaded } else { profile = await social.profile(for: userID) }
        if !isSelf { isFollowing = await social.isFollowing(userID) }
        recent = await social.recentWorkouts(for: userID, limit: Self.previewLimit)
        loaded = true
    }

    /// The button state only moves on backend success. The old optimistic
    /// flip made a rejected write look like a follow that mysteriously never
    /// stuck — surfacing the server's reason is also the field diagnostic
    /// for schema/permission gaps CloudKit only reveals on a real device.
    private func toggleFollow() async {
        busy = true
        defer { busy = false }
        followError = nil
        do {
            if isFollowing {
                try await social.unfollow(userID)
                isFollowing = false
            } else {
                try await social.follow(userID)
                isFollowing = true
            }
        } catch {
            followError = "\(isFollowing ? "Unfollow" : "Follow") didn't save: \(error.localizedDescription)"
        }
    }
}
