import SwiftUI

struct RoutineOrganizerEntryRow: View {
    let draft: RoutineOrganizerDraft
    let entry: RoutineOrganizerDraft.Entry

    var body: some View {
        switch entry.kind {
        case .ungrouped(let count):
            RoutineOrganizerUngroupedRow(count: count)
        case .folder(let folderID, _, let depth):
            RoutineOrganizerFolderRow(
                draft: draft,
                folderID: folderID,
                depth: depth
            )
        case .routine(let item, let destination, let depth):
            RoutineOrganizerRoutineRow(
                draft: draft,
                item: item,
                destination: destination,
                depth: depth
            )
        }
    }
}
