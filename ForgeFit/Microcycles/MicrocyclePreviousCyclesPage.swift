import ForgeData
import SwiftData
import SwiftUI

struct MicrocyclePreviousCyclesPage: View {
    @Query private var windows: [MicrocycleWindowModel]
    @Binding var page: Int
    let cutoff: Date

    init(trackingID: UUID, currentWindowID: UUID?, cutoff: Date, page: Binding<Int>) {
        self.cutoff = cutoff
        _page = page
        _windows = Query(MicrocyclePreviousCyclesQuery.descriptor(
            trackingID: trackingID, currentWindowID: currentWindowID,
            cutoff: cutoff, limit: MicrocyclePreviousCyclesQuery.pageSize,
            offset: page.wrappedValue * MicrocyclePreviousCyclesQuery.pageSize
        ))
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Button { page -= 1 } label: {
                    Label("Newer", systemImage: "chevron.left")
                        .frame(minHeight: TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                    .disabled(page == 0)
                    .accessibilityIdentifier("microcycle-history-newer")
                Spacer()
                Text("Page \(page + 1)")
                    .font(.subheadline)
                    .accessibilityIdentifier("microcycle-history-page")
                Spacer()
                Button { page += 1 } label: {
                    Label("Older", systemImage: "chevron.right")
                        .frame(minHeight: TouchTarget.minimum)
                        .contentShape(Rectangle())
                }
                    .disabled(windows.count <= MicrocyclePreviousCyclesQuery.pageSize)
                    .accessibilityIdentifier("microcycle-history-older")
            }
            .frame(minHeight: TouchTarget.minimum)

            if windows.isEmpty {
                ContentUnavailableView("No Previous Cycles", systemImage: "calendar.badge.clock")
            }
            ForEach(windows.prefix(MicrocyclePreviousCyclesQuery.pageSize)) { window in
                MicrocyclePreviousCycleRow(window: window, cutoff: cutoff)
            }
        }
    }
}
