import SwiftUI

struct RoutineOrganizerRoutineRow: View {
    @Environment(\.theme) private var theme

    let draft: RoutineOrganizerDraft
    let item: RoutineOrganizerDraft.RoutineItem
    let destination: RoutineOrganizerDraft.Destination
    let depth: Int

    var body: some View {
        HStack(spacing: Space.md) {
            if depth > 1 {
                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 1, height: 44)
                    .accessibilityHidden(true)
            }
            Image(systemName: item.routineIDs.count > 1
                ? "arrow.triangle.2.circlepath"
                : "list.bullet.clipboard")
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(item.name)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Space.sm)
            if draft.routineDestinations.count > 1 {
                Menu {
                    ForEach(draft.routineDestinations.filter { $0 != destination }, id: \.self) { target in
                        Button(
                            "Move to \(draft.destinationLabel(target))",
                            systemImage: target.folderID == nil ? "tray" : "folder"
                        ) {
                            draft.moveRoutine(item.id, to: target)
                        }
                    }
                } label: {
                    RoutineOrganizerPlacementMenuLabel()
                }
                .buttonStyle(.plain)
                .padding(.trailing, Space.sm)
                .accessibilityLabel("Placement options for routine \(item.name)")
                .accessibilityIdentifier("move-organizer-routine-\(item.id.uuidString)")
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.sm)
        .padding(.leading, depth == 1 ? Space.md : Space.xl)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .listRowBackground(theme.background)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("organize-routine-\(item.id.uuidString)")
    }
}
