import SwiftUI

struct MicrocycleHistoryRunCard: View {
    @Environment(\.theme) private var theme

    let run: MicrocycleHistoryRunPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.folderName)
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(runSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: Space.sm)
                Text(run.isActive ? "TRACKING" : "STOPPED")
                    .font(.tag)
                    .foregroundStyle(run.isActive ? theme.accent : theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(run.isActive ? theme.accentSoft : theme.surfaceElevated)
                    .clipShape(Capsule())
            }

            if run.windows.isEmpty {
                Text("No tracked cycles were recorded in this run.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.vertical, Space.sm)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(run.windows.enumerated()), id: \.element.id) { offset, window in
                        if offset > 0 {
                            Divider().overlay(theme.separator)
                        }
                        NavigationLink(
                            value: MicrocycleHistoryRoute.window(
                                trackingID: run.trackingID,
                                windowID: window.windowID
                            )
                        ) {
                            MicrocycleHistoryWindowRow(window: window)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "microcycle-history-window-\(run.trackingID.uuidString)-\(window.cycleNumber)"
                        )
                    }
                }
            }
        }
        .padding(Space.md)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card)
                .stroke(theme.separator, lineWidth: 1)
        }
    }

    private var runSubtitle: String {
        let target = "\(run.durationDays)-day target"
        if let endedAt = run.endedAt {
            return "\(run.startsAt.formatted(date: .abbreviated, time: .omitted))–\(endedAt.formatted(date: .abbreviated, time: .omitted)) · \(target)"
        }
        return "Started \(run.startsAt.formatted(date: .abbreviated, time: .omitted)) · \(target)"
    }
}
