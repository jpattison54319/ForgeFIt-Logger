import SwiftUI
import ForgeData

/// Likes a workout earned from friends, shown on the OWN workout-history
/// detail page — the one place you learn your training was appreciated.
/// The row is state-stable: zero likes remain visible, while a failed fetch is
/// explicit instead of making the field disappear. Likes are ephemeral view
/// state; they must never be persisted
/// into a SwiftData model (see `SocialService.WorkoutHearts`).
struct WorkoutHeartsRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(SocialService.self) private var social
    let workoutID: UUID

    @State private var hearts: SocialService.WorkoutHearts?
    @State private var didLoad = false
    @State private var showLikers = false

    var body: some View {
        Group {
            if let hearts {
                Button { showLikers = true } label: {
                    Card(padding: Space.md) {
                        HStack(spacing: Space.md) {
                            Image(systemName: hearts.count > 0 ? "heart.fill" : "heart")
                                .font(.system(size: 16))
                                .foregroundStyle(hearts.count > 0 ? theme.danger : theme.textSecondary)
                                .frame(width: 32)
                            Text(Self.countText(hearts.count))
                                .font(.bodyStrong).foregroundStyle(theme.textPrimary)
                            if let leadName = hearts.leadName {
                                Text(Self.likersLine(leadName: leadName, total: hearts.count))
                                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilitySummary(leadName: hearts.leadName, total: hearts.count))
                .accessibilityIdentifier("workout-hearts-row")
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if didLoad {
                Card(padding: Space.md) {
                    HStack(spacing: Space.md) {
                        Image(systemName: "heart.slash")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 32)
                        Text("Likes unavailable")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                    }
                }
                .accessibilityIdentifier("workout-hearts-row")
            } else {
                Card(padding: Space.md) {
                    HStack(spacing: Space.md) {
                        Image(systemName: "heart")
                            .font(.system(size: 16))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 32)
                        Text("Likes")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        ProgressView()
                    }
                }
                .accessibilityIdentifier("workout-hearts-row")
            }
            #if DEBUG
            // Automation probe: distinguishes "not fetched yet" from
            // "fetched, zero hearts". Invisible, zero-size.
            Color.clear.frame(width: 0, height: 0)
                .accessibilityIdentifier("hearts-fetch-\(hearts.map { "count-\($0.count)" } ?? "nil")")
            #endif
        }
        .animation(reduceMotion ? Motion.reduced : Motion.entrance, value: hearts?.count)
        .task(id: workoutID) {
            // One fetch per detail open (60 s service-side cache absorbs
            // back-to-back opens). A failed fetch keeps an explicit unavailable
            // row in place; there is no automatic retry loop.
            hearts = nil
            didLoad = false
            hearts = await social.hearts(workoutID: workoutID)
            didLoad = true
        }
        .sheet(isPresented: $showLikers) {
            if let hearts {
                WorkoutLikersSheet(likes: hearts.likes)
            }
        }
    }

    /// "Mia Chen" / "Mia Chen +2" — the most recent like leads, overflow
    /// collapses to a count. A liker whose profile is gone shows no name;
    /// the count still includes them.
    static func likersLine(leadName: String?, total: Int) -> String {
        let overflow = total - 1
        guard let leadName else { return "" }
        return overflow > 0 ? "\(leadName) +\(overflow)" : leadName
    }

    static func countText(_ total: Int) -> String {
        total == 1 ? "1 like" : "\(total) likes"
    }

    static func accessibilitySummary(leadName: String?, total: Int) -> String {
        let likes = countText(total)
        guard let leadName else { return likes }
        let others = total - 1
        if others == 0 { return "\(likes), from \(leadName)" }
        return "\(likes), most recently from \(leadName) and \(others) other\(others == 1 ? "" : "s")"
    }
}

/// Everyone who liked the workout, newest first. Rows with a live profile
/// open it; a deleted account renders as "Athlete" with no disclosure.
private struct WorkoutLikersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(SocialService.self) private var social
    let likes: [SocialLike]

    @State private var opened: OpenedProfile?
    private struct OpenedProfile: Identifiable, Hashable {
        let profile: SocialProfile
        var id: String { profile.userID.rawValue }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.md) {
                    HStack {
                        Text("Likes").font(.cardTitle).foregroundStyle(theme.textPrimary)
                        Spacer()
                        CircleIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                    }
                    .padding(.top, Space.lg)

                    if likes.isEmpty {
                        EmptyStateCard(
                            title: "0 likes",
                            message: "Nobody has liked this workout yet.",
                            systemImage: "heart"
                        )
                    } else {
                        ForEach(likes, id: \.userID.rawValue) { like in
                            LikerRow(like: like) { profile in
                                opened = OpenedProfile(profile: profile)
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.lg)
            }
            .background(theme.background)
            .navigationDestination(item: $opened) { item in
                SocialProfileScreen(userID: item.profile.userID, preloaded: item.profile)
            }
        }
    }
}

private struct LikerRow: View {
    @Environment(\.theme) private var theme
    @Environment(SocialService.self) private var social
    let like: SocialLike
    let onOpen: (SocialProfile) -> Void

    /// nil = still resolving; .some(nil) = profile deleted.
    @State private var profile: SocialProfile??

    var body: some View {
        Button {
            if case .some(.some(let profile)) = profile { onOpen(profile) }
        } label: {
            Card(padding: Space.md) {
                HStack(spacing: Space.md) {
                    ZStack {
                        Circle().fill(theme.recoveryHigh.opacity(0.9)).frame(width: 42, height: 42)
                        Text(socialInitials(displayName)).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    if case .some(.some) = profile {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: like.userID.rawValue) {
            profile = .some(await social.likerProfile(for: like.userID))
        }
    }

    private var isSelf: Bool { like.userID == social.myUserID }

    private var displayName: String {
        if isSelf { return "You" }
        if case .some(.some(let profile)) = profile { return profile.displayName }
        return "Athlete"
    }

    private var subtitle: String {
        var parts: [String] = []
        if case .some(.some(let profile)) = profile, !isSelf { parts.append("@\(profile.handle)") }
        parts.append(like.likedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}
