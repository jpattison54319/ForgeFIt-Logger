import ForgeCore
import Foundation

struct MicrocycleHistoryWindowPresentation: Identifiable, Equatable {
    let trackingID: UUID
    let windowID: UUID
    let cycleNumber: Int
    let startsAt: Date
    let visibleEndsAt: Date
    let scheduledEndsAt: Date
    let state: MicrocycleHistoryWindowState
    let progress: MicrocycleProgress

    var id: UUID { windowID }
}
