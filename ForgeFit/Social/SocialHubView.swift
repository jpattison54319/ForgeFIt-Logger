import ForgeData
import SwiftUI

/// The social home: opt-in gate, your public profile, your friends (tap to
/// visit), find-friends, and leaderboards. Pushed from Profile's Dashboard.
struct SocialHubView: View {
    @Environment(\.theme) private var theme
    @Environment(SocialService.self) private var social
    let makeSnapshot: () -> ProfileSnapshot

    @State private var showOptIn = false
    @State private var friends: [SocialProfile] = []
    @State private var loadingFriends = false
    @State private var linked: IdentifiedProfile?

    private struct IdentifiedProfile: Identifiable { let profile: SocialProfile; var id: String { profile.userID.rawValue } }

    var body: some View {
        ScreenScaffold("Community", trailing: { if social.isDemo { demoChip } }) {
            switch social.status {
            case .loading:
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xl)
            case .unavailable(let message):
                EmptyStateCard(title: "Social unavailable", message: message, systemImage: "icloud.slash")
            case .notOptedIn:
                optInCard
            case .active:
                activeContent
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showOptIn) {
            SocialOptInView(makeSnapshot: makeSnapshot)
        }
        .sheet(item: $linked) { item in NavigationStack { SocialProfileScreen(userID: item.profile.userID, preloaded: item.profile) } }
        .task { await syncAndLoad() }
        .onChange(of: social.status) { _, _ in Task { await syncAndLoad() } }
        .onChange(of: social.pendingFollowHandle) { _, _ in Task { await consumePendingLink() } }
    }

    private var demoChip: some View {
        Text("DEMO").font(.system(size: 11, weight: .heavy)).foregroundStyle(theme.warmup)
            .padding(.horizontal, 8).padding(.vertical, 4).background(theme.warmup.opacity(0.15)).clipShape(Capsule())
    }

    private var optInCard: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    Image(systemName: "person.2.fill").font(.system(size: 28)).foregroundStyle(theme.accent)
                    Text("Train with friends").font(.sectionTitle).foregroundStyle(theme.textPrimary)
                    Text("Follow friends to see their workouts and stats, and compare on leaderboards. Your workouts share as **training data only** — never health data. Private until you turn it on.")
                        .font(.system(size: 14)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            PrimaryButton(title: "Enable Social", systemImage: "person.2.fill") { showOptIn = true }
                .accessibilityIdentifier("social-enable")
        }
    }

    @ViewBuilder private var activeContent: some View {
        if let me = social.myProfile {
            Button { linked = IdentifiedProfile(profile: me) } label: {
                SocialProfileHeaderView(profile: me)
            }
            .buttonStyle(.plain)
            HStack(spacing: Space.md) {
                NavigationLink { AddFriendView() } label: {
                    hubAction("person.badge.plus", "Find friends")
                }.buttonStyle(.plain)
                ShareLink(item: SocialLinks.appURL(handle: me.handle), message: Text(SocialLinks.shareText(handle: me.handle))) {
                    hubAction("square.and.arrow.up", "Share link")
                }
            }
            NavigationLink { LeaderboardView() } label: { hubRow("trophy.fill", "Leaderboards", "Friends & global — strength, cardio, yoga") }
                .buttonStyle(.plain)
        }

        SectionHeader("Friends")
        if loadingFriends {
            ProgressView().frame(maxWidth: .infinity)
        } else if friends.isEmpty {
            EmptyStateCard(title: "No friends yet", message: "Share your link or find friends by handle to start following.", systemImage: "person.2")
        } else {
            ForEach(friends, id: \.userID) { friend in
                NavigationLink { SocialProfileScreen(userID: friend.userID, preloaded: friend) } label: { friendRow(friend) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func hubAction(_ icon: String, _ title: String) -> some View {
        VStack(spacing: Space.xs) {
            Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.accent)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.md)
        .background(theme.surface).clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func hubRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(theme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func friendRow(_ friend: SocialProfile) -> some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                ZStack {
                    Circle().fill(theme.recoveryHigh.opacity(0.9)).frame(width: 42, height: 42)
                    Text(socialInitials(friend.displayName)).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
                    Text("@\(friend.handle) · Level \(XPService.progress(forTotalXP: friend.totalXP).level)")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func syncAndLoad() async {
        if social.isOptedIn {
            await social.syncMyProfile(makeSnapshot(), displayName: social.myProfile?.displayName ?? "Athlete")
        }
        await loadFriends()
        await consumePendingLink()
    }

    private func loadFriends() async {
        loadingFriends = true
        var result: [SocialProfile] = []
        for id in await social.following() {
            if let p = await social.profile(for: id) { result.append(p) }
        }
        friends = result.sorted { $0.displayName < $1.displayName }
        loadingFriends = false
    }

    private func consumePendingLink() async {
        guard let handle = social.pendingFollowHandle else { return }
        social.pendingFollowHandle = nil
        if let profile = await social.lookup(handle: handle) { linked = IdentifiedProfile(profile: profile) }
    }
}
