import SwiftUI

struct RoutineOrganizerFolderRow: View {
    @Environment(\.theme) private var theme

    let draft: RoutineOrganizerDraft
    let folderID: UUID
    let depth: Int

    var body: some View {
        HStack(spacing: Space.sm) {
            if depth > 0 {
                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 1, height: 44)
                    .accessibilityHidden(true)
            }
            Image(systemName: "folder.fill")
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(draft.folderNames[folderID, default: "Folder"])
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            let count = draft.contentCount(for: folderID)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(theme.surfaceElevated)
                    .clipShape(Capsule())
            }
            Spacer(minLength: Space.sm)
            if hasPlacementOptions {
                placementMenu
            }
        }
        .padding(.leading, depth == 0 ? 0 : Space.md)
        .listRowBackground(theme.background)
        .listRowSeparator(.hidden)
        .accessibilityIdentifier("organize-folder-\(folderID.uuidString)")
    }

    private var hasPlacementOptions: Bool {
        draft.parentID(of: folderID) != nil || !draft.validParents(for: folderID).isEmpty
    }

    private var placementMenu: some View {
        let parents = draft.validParents(for: folderID)
        let showsTopLevel = draft.parentID(of: folderID) != nil
        return Menu {
            if showsTopLevel {
                Button("Top Level", systemImage: "arrow.up.to.line") {
                    draft.moveFolder(folderID, to: nil)
                }
            }
            ForEach(parents, id: \.self) { parentID in
                Button("Move into \(draft.folderNames[parentID, default: "Folder"])", systemImage: "folder") {
                    draft.moveFolder(folderID, to: parentID)
                }
            }
        } label: {
            RoutineOrganizerPlacementMenuLabel()
        }
        .buttonStyle(.plain)
        .padding(.trailing, Space.sm)
        .accessibilityLabel("Placement options for folder \(draft.folderNames[folderID, default: "Folder"])")
        .accessibilityIdentifier("move-organizer-folder-\(folderID.uuidString)")
    }
}
