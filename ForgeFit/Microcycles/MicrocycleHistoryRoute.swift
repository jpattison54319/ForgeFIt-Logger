import Foundation

enum MicrocycleHistoryRoute: Hashable {
    case previousCycles(trackingID: UUID, currentWindowID: UUID?, cutoff: Date)
    case window(trackingID: UUID, windowID: UUID)
}
