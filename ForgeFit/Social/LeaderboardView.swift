import ForgeData
import SwiftUI

/// Friends and global leaderboards across strength, cardio, and yoga. Global
/// boards are "for fun, not authoritative" — values are client-submitted and
/// unverifiable, matching the app's honest-framing stance.
struct LeaderboardView: View {
    @Environment(\.theme) private var theme
    @Environment(SocialService.self) private var social

    @State private var scope: LeaderboardScope = .friends
    @State private var metric: SocialLeaderboardMetric = .xp
    @State private var entries: [SocialLeaderboardEntry] = []
    @State private var loading = true

    /// One representative metric per category for the top-level picker.
    private let categories: [SocialLeaderboardMetric] = [.xp, .totalVolume, .cardioDistance, .yogaMinutes]

    var body: some View {
        ScreenScaffold("Leaderboards", trailing: { EmptyView() }) {
            SegmentedPills(options: [.friends, .global], title: scopeTitle, selection: $scope)
            SegmentedPills(options: categories, title: categoryTitle, selection: $metric)

            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Space.xl)
            } else if entries.isEmpty {
                EmptyStateCard(title: "No one here yet",
                               message: scope == .friends ? "Follow some friends to see how you stack up." : "Be the first on the board.",
                               systemImage: "trophy")
            } else {
                Card {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            NavigationLink { SocialProfileScreen(userID: entry.profile.userID, preloaded: entry.profile) } label: {
                                row(entry)
                            }
                            .buttonStyle(.plain)
                            if entry.id != entries.last?.id { Divider().overlay(theme.separator) }
                        }
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: TaskKey(scope: scope, metric: metric)) { await load() }
    }

    private struct TaskKey: Equatable { var scope: LeaderboardScope; var metric: SocialLeaderboardMetric }

    private func row(_ entry: SocialLeaderboardEntry) -> some View {
        HStack(spacing: Space.md) {
            Text("\(entry.rank)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(entry.rank <= 3 ? theme.accent : theme.textTertiary)
                .frame(width: 28, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.profile.displayName).font(.bodyStrong).foregroundStyle(theme.textPrimary).lineLimit(1)
                Text("@\(entry.profile.handle)").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
            }
            Spacer()
            Text(valueText(entry.value)).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.textSecondary)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textTertiary)
        }
        .padding(.vertical, Space.sm)
        .contentShape(Rectangle())
    }

    private func scopeTitle(_ scope: LeaderboardScope) -> String { scope == .friends ? "Friends" : "Global" }
    private func categoryTitle(_ metric: SocialLeaderboardMetric) -> String {
        switch metric {
        case .xp: "Overall"
        case .totalVolume, .bestE1RM: "Strength"
        case .cardioDistance, .cardioMinutes: "Cardio"
        case .yogaMinutes: "Yoga"
        }
    }

    private func valueText(_ value: Double) -> String {
        switch metric {
        case .xp: "\(Int(value)) XP"
        case .totalVolume: Fmt.volume(value)
        case .bestE1RM: Fmt.loadUnit(value)
        case .cardioDistance: Fmt.distance(value)
        case .cardioMinutes, .yogaMinutes: "\(Int(value)) min"
        }
    }

    private func load() async {
        loading = true
        entries = await social.leaderboard(metric: metric, scope: scope)
        loading = false
    }
}
