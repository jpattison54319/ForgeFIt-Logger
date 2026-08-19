import Foundation

struct MicrocycleHistoryRunPresentation: Identifiable, Equatable {
    let trackingID: UUID
    let folderName: String
    let startsAt: Date
    let endedAt: Date?
    let durationDays: Int
    let isActive: Bool
    let windows: [MicrocycleHistoryWindowPresentation]

    var id: UUID { trackingID }
}
