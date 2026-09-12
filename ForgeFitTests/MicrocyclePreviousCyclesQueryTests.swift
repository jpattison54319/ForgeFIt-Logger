import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct MicrocyclePreviousCyclesQueryTests {
    @Test func boundedPagesReachEveryCycleAndExcludeOtherRunsDeletedAndFutureWindows() throws {
        let container = try TestStore.makeContainer()
        let context = ModelContext(container)
        let trackingID = UUID()
        let currentID = UUID()
        let cutoff = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 0..<1_005 {
            let window = MicrocycleWindowModel(
                userID: UUID(),
                trackingID: index == 1_001 ? UUID() : trackingID,
                folderID: UUID(), folderName: "History",
                index: index,
                startsAt: cutoff.addingTimeInterval(Double(index - 1_003) * 86_400),
                endsAt: cutoff.addingTimeInterval(Double(index - 1_002) * 86_400),
                timeZoneIdentifier: "UTC", routines: []
            )
            if index == 1_000 { window.id = currentID }
            if index == 1_002 { window.deletedAt = cutoff }
            context.insert(window)
        }
        try context.save()
        let freshContext = ModelContext(container)
        let preview = try freshContext.fetch(MicrocyclePreviousCyclesQuery.descriptor(
            trackingID: trackingID, currentWindowID: currentID, cutoff: cutoff, limit: 3
        ))
        #expect(preview.map(\.index) == [999, 998, 997, 996])
        var indices: [Int] = []
        for page in 0..<50 {
            let windows = try freshContext.fetch(MicrocyclePreviousCyclesQuery.descriptor(
                trackingID: trackingID, currentWindowID: currentID,
                cutoff: cutoff, limit: 20, offset: page * 20
            ))
            #expect(windows.count == (page == 49 ? 20 : 21))
            indices.append(contentsOf: windows.prefix(20).map(\.index))
        }
        #expect(indices == Array((0..<1_000).reversed()))
        let withNoCurrentWindow = try freshContext.fetch(MicrocyclePreviousCyclesQuery.descriptor(
            trackingID: trackingID, currentWindowID: nil, cutoff: cutoff, limit: 3
        ))
        #expect(withNoCurrentWindow.first?.id == currentID)
    }
}
