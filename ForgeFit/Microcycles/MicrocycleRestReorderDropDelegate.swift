import SwiftUI
import UniformTypeIdentifiers

struct MicrocycleRestReorderDropDelegate: DropDelegate {
    struct Drag {
        let restDayID: UUID
        let windowID: UUID
        let token = UUID().uuidString

        func makeItemProvider() -> NSItemProvider {
            let provider = NSItemProvider()
            provider.suggestedName = token
            let data = Data(token.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .ownProcess) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
    }

    struct Insertion: Equatable {
        let index: Int
        let y: CGFloat
    }

    let windowID: UUID
    let itemIDs: [UUID]
    let rowFrames: () -> [UUID: CGRect]
    @Binding var drag: Drag?
    @Binding var insertion: Insertion?
    let onCommit: (UUID, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        drag?.windowID == windowID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = insertion(at: info.location.y)
        if insertion != target { insertion = target }
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        insertion = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            drag = nil
            insertion = nil
        }
        guard let drag,
              let target = insertion(at: info.location.y),
              info.itemProviders(for: [.plainText]).contains(where: { $0.suggestedName == drag.token }) else { return false }
        onCommit(drag.restDayID, target.index)
        return true
    }

    private func insertion(at y: CGFloat) -> Insertion? {
        guard let drag, drag.windowID == windowID, itemIDs.contains(drag.restDayID) else { return nil }
        let frames = rowFrames()
        var index = 0
        var lastFrame: CGRect?
        for id in itemIDs where id != drag.restDayID {
            guard let frame = frames[id] else { return nil }
            if y < frame.midY {
                return Insertion(index: index, y: max(1, frame.minY - Space.sm / 2))
            }
            lastFrame = frame
            index += 1
        }
        guard let lastFrame else { return nil }
        return Insertion(index: index, y: lastFrame.maxY - 1)
    }
}
