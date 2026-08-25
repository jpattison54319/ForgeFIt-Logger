import SwiftUI

struct RoutineOrganizerRoutineRow: View {
    @Environment(\.theme) private var theme

    let draft: RoutineOrganizerDraft
    let item: RoutineOrganizerDraft.RoutineItem
    let destination: RoutineOrganizerDraft.Destination
    let depth: Int

    var body: some View {
        HStack(spacing: Space.md) {
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
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .padding(.leading, cardIndent)
        .padding(.vertical, Space.xs)
        .overlay {
            if destination.folderID != nil {
                RoutineOrganizerHierarchyRail(
                    x: railX,
                    startsAtMidpoint: false,
                    endsAtMidpoint: isLastRoutine,
                    branchEndX: nil
                )
                if hasLaterSiblingFolder {
                    RoutineOrganizerHierarchyRail(
                        x: ancestorRailX,
                        startsAtMidpoint: false,
                        endsAtMidpoint: false,
                        branchEndX: nil
                    )
                }
            }
        }
        .listRowBackground(theme.background)
        .listRowInsets(
            EdgeInsets(top: 0, leading: Space.lg, bottom: 0, trailing: Space.lg)
        )
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("organize-routine-\(item.id.uuidString)")
    }

    private var cardIndent: CGFloat {
        depth == 1 ? Space.xl : Space.xxl + Space.md
    }

    private var railX: CGFloat {
        depth == 1 ? 10 : Space.md + 1 + Space.sm + 10
    }

    private var ancestorRailX: CGFloat {
        10
    }

    private var isLastRoutine: Bool {
        draft.routines(in: destination).last?.id == item.id
    }

    private var hasLaterSiblingFolder: Bool {
        guard depth > 1, let folderID = destination.folderID,
              let parentID = draft.parentID(of: folderID) else { return false }
        let siblings = draft.children(of: parentID)
        guard let index = siblings.firstIndex(of: folderID) else { return false }
        return index < siblings.count - 1
    }
}
