import SwiftUI

struct MicrocyclePreviousCyclesView: View {
    @Environment(\.theme) private var theme
    @State private var page = 0
    let trackingID: UUID
    let currentWindowID: UUID?
    let cutoff: Date

    var body: some View {
        ScrollView {
            MicrocyclePreviousCyclesPage(
                trackingID: trackingID, currentWindowID: currentWindowID,
                cutoff: cutoff, page: $page
            )
            .padding(Space.lg)
            .padding(.bottom, Space.tabBarClearance)
        }
        .id(page)
        .background(theme.background)
        .navigationTitle("Previous Cycles")
        .navigationBarTitleDisplayMode(.inline)
    }
}
