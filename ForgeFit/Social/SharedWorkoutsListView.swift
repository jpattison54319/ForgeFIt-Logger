import ForgeData
import SwiftUI

/// An athlete's complete shared-workout history, loaded a page at a time.
/// Keyset pagination (`before:` = last row's `publishedAt`) so each page is
/// one bounded summary-only query no matter how deep the history goes; the
/// next page loads when the last row scrolls into view.
struct SharedWorkoutsListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(SocialService.self) private var social
    let userID: SocialUserID
    let ownerName: String

    @State private var refs: [SocialWorkoutRef] = []
    @State private var loading = false
    @State private var exhausted = false

    private static let pageSize = 25

    /// Viewing your own list (pushed from the hub) — the empty state speaks
    /// to you, not about you in the third person.
    private var isOwnList: Bool { social.myProfile?.userID == userID }

    var body: some View {
        // `lazy` so rows build on scroll — that's also what makes the
        // last-row `onAppear` a reliable load-more trigger.
        DashboardScaffold(title: "All Workouts", dismiss: dismiss, lazy: true) {
            ForEach(refs) { ref in
                NavigationLink { SharedWorkoutDetailView(ref: ref, ownerName: ownerName) } label: {
                    SocialWorkoutRow(ref: ref)
                }
                .buttonStyle(.plain)
                .onAppear {
                    if ref.id == refs.last?.id { Task { await loadMore() } }
                }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, Space.md)
            } else if refs.isEmpty && exhausted {
                EmptyStateCard(
                    title: "No shared workouts",
                    message: isOwnList
                        ? "Workouts you log in ForgeFit publish here automatically."
                        : "When \(ownerName) logs a workout, it shows up here.",
                    systemImage: "dumbbell"
                )
            }
        }
        .task { await loadMore() }
    }

    private func loadMore() async {
        guard !loading, !exhausted else { return }
        loading = true
        let page = await social.recentWorkouts(for: userID, limit: Self.pageSize, before: refs.last?.publishedAt)
        // Strictly-before keyset can't duplicate, but a ref re-published
        // mid-scroll could reappear — drop anything already listed so
        // ForEach identity stays unique.
        let known = Set(refs.map(\.id))
        refs.append(contentsOf: page.filter { !known.contains($0.id) })
        exhausted = page.count < Self.pageSize
        loading = false
    }
}
