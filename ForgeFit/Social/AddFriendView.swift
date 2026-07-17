import ForgeData
import SwiftUI

/// Find another athlete by handle (or paste a `forgefit://u/<handle>` link) and
/// open their profile to follow. This is the v1 discovery path — no global
/// people-search index yet.
struct AddFriendView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social

    @State private var query = ""
    @State private var result: SocialProfile?
    @State private var searched = false
    @State private var searching = false

    var body: some View {
        DashboardScaffold(title: "Find friends", dismiss: dismiss) {
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    HStack {
                        Text("@").font(.bodyStrong).foregroundStyle(theme.textSecondary)
                        TextField("handle or pasted link", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit { Task { await search() } }
                        if searching { ProgressView().controlSize(.small) }
                    }
                    Text("Ask a friend for their @handle, or paste the link they shared.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
            }
            PrimaryButton(title: "Search", systemImage: "magnifyingglass") { Task { await search() } }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)

            if let result {
                NavigationLink { SocialProfileScreen(userID: result.userID, preloaded: result) } label: { resultRow(result) }
                    .buttonStyle(.plain)
            } else if searched {
                EmptyStateCard(title: "No match", message: "No athlete found with that handle.", systemImage: "person.slash")
            }
        }
    }

    private func resultRow(_ profile: SocialProfile) -> some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                ZStack {
                    Circle().fill(theme.recoveryHigh.opacity(0.9)).frame(width: 44, height: 44)
                    Text(socialInitials(profile.displayName)).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Text("@\(profile.handle) · Level \(XPService.progress(forTotalXP: profile.totalXP).level)")
                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func parsedHandle() -> String {
        if let url = URL(string: query.trimmingCharacters(in: .whitespaces)), let handle = SocialLinks.handle(from: url) { return handle }
        return SocialHandle.normalize(query)
    }

    private func search() async {
        searching = true
        searched = false
        result = await social.lookup(handle: parsedHandle())
        searched = true
        searching = false
    }
}
