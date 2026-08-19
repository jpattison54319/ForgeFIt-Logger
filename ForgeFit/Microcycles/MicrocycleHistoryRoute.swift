import Foundation

enum MicrocycleHistoryRoute: Hashable {
    case window(trackingID: UUID, windowID: UUID)
}
