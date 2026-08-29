import SwiftUI

struct MicrocycleRestReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedRestDayID: UUID?
    @Binding var previewItemIDs: [UUID]
    let reduceMotion: Bool
    let onCommit: (UUID, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedRestDayID,
              draggedRestDayID != targetID,
              let sourceIndex = previewItemIDs.firstIndex(of: draggedRestDayID),
              let targetIndex = previewItemIDs.firstIndex(of: targetID) else { return }

        let updatePreview = {
            previewItemIDs.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
        }
        if reduceMotion {
            updatePreview()
        } else {
            withAnimation(.snappy(duration: 0.18), updatePreview)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggedRestDayID,
              let destination = previewItemIDs.firstIndex(of: draggedRestDayID) else {
            cancelPreview()
            return false
        }
        onCommit(draggedRestDayID, destination)
        cancelPreview()
        return true
    }

    private func cancelPreview() {
        draggedRestDayID = nil
        previewItemIDs = []
    }
}
