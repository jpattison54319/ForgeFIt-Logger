import ForgeData
import SwiftData
import SwiftUI

struct MicrocyclePreviousCyclesSection: View {
    @Environment(\.theme) private var theme
    @Query private var windows: [MicrocycleWindowModel]

    let trackingID: UUID
    let currentWindowID: UUID?
    let cutoff: Date

    init(trackingID: UUID, currentWindowID: UUID?, cutoff: Date) {
        self.trackingID = trackingID
        self.currentWindowID = currentWindowID
        self.cutoff = cutoff
        _windows = Query(MicrocyclePreviousCyclesQuery.descriptor(
            trackingID: trackingID, currentWindowID: currentWindowID,
            cutoff: cutoff, limit: MicrocyclePreviousCyclesQuery.previewSize
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Previous Cycles")
                    .font(.sectionTitle)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: Space.sm)
                if windows.count > MicrocyclePreviousCyclesQuery.previewSize {
                    NavigationLink(value: MicrocycleHistoryRoute.previousCycles(
                        trackingID: trackingID, currentWindowID: currentWindowID, cutoff: cutoff
                    )) {
                        Text("View All")
                            .font(.bodyStrong)
                            .frame(minHeight: TouchTarget.minimum)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("View All Previous Cycles")
                    .accessibilityIdentifier("microcycle-view-all-previous-cycles")
                }
            }
            if windows.isEmpty {
                Card {
                    Text("Completed cycles will appear here.")
                        .font(.body)
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                ForEach(windows.prefix(MicrocyclePreviousCyclesQuery.previewSize)) { window in
                    MicrocyclePreviousCycleRow(window: window, cutoff: cutoff)
                }
            }
        }
    }
}
