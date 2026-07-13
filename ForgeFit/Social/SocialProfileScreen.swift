import ForgeData
import SwiftUI

/// Another athlete's profile — their stats + level (mirroring your own Profile
/// screen) and their recent shared workouts. Also used to preview your own
/// public profile.
struct SocialProfileScreen: View {
    @Environment(\.theme) private var theme
    @Environment(SocialService.self) private var social
    let userID: SocialUserID
    var preloaded: SocialProfile?

    @State private var profile: SocialProfile?
    @State private var recent: [SocialWorkoutRef] = []
    @State private var isFollowing = false
    @State private var loaded = false
    @State private var busy = false

    private var isSelf: Bool { social.myUserID == userID }

    var body: some View {
        ScreenScaffold(profile?.displayName ?? "Profile", trailing: { EmptyView() }) {
            if let profile {
                SocialProfileHeaderView(profile: profile)
                if !isSelf { followButton }

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
                }
            } else if loaded {
                EmptyStateCard(title: "Profile unavailable", message: "This athlete isn't on ForgeFit social, or their profile is private.", systemImage: "person.slash")
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xl)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
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
        recent = await social.recentWorkouts(for: userID)
        loaded = true
    }

    private func toggleFollow() async {
        busy = true
        defer { busy = false }
        if isFollowing { await social.unfollow(userID) } else { await social.follow(userID) }
        isFollowing.toggle()
    }
}
