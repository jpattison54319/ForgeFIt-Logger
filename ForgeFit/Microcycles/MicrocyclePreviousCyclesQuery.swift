import ForgeData
import Foundation
import SwiftData

enum MicrocyclePreviousCyclesQuery {
    static let previewSize = 3
    static let pageSize = 20

    static func descriptor(
        trackingID: UUID,
        currentWindowID: UUID?,
        cutoff: Date,
        limit: Int,
        offset: Int = 0
    ) -> FetchDescriptor<MicrocycleWindowModel> {
        let predicate: Predicate<MicrocycleWindowModel>
        if let currentWindowID {
            predicate = #Predicate {
                $0.trackingID == trackingID && $0.deletedAt == nil
                    && $0.id != currentWindowID && $0.startsAt < cutoff
            }
        } else {
            predicate = #Predicate {
                $0.trackingID == trackingID && $0.deletedAt == nil && $0.startsAt < cutoff
            }
        }
        var descriptor = FetchDescriptor<MicrocycleWindowModel>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\MicrocycleWindowModel.index, order: .reverse),
                SortDescriptor(\MicrocycleWindowModel.id)
            ]
        )
        // One lookahead record reveals whether another page exists.
        descriptor.fetchLimit = limit + 1
        descriptor.fetchOffset = offset
        return descriptor
    }
}
