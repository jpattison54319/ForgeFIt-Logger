import CoreFoundation
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleCompactDayLayoutTests {
    @Test func keepsFirstTenMarkersOnOneRow() {
        #expect(MicrocycleCompactDayLayout.columnCount(itemCount: 9) == 9)
        #expect(MicrocycleCompactDayLayout.rowCount(itemCount: 9) == 1)
        #expect(MicrocycleCompactDayLayout.columnCount(itemCount: 10) == 10)
        #expect(MicrocycleCompactDayLayout.rowCount(itemCount: 10) == 1)
    }

    @Test func wrapsAfterTenMarkers() {
        #expect(MicrocycleCompactDayLayout.columnCount(itemCount: 11) == 10)
        #expect(MicrocycleCompactDayLayout.rowCount(itemCount: 11) == 2)
        #expect(MicrocycleCompactDayLayout.rowCount(itemCount: 31) == 4)
    }

    @Test func emptyLayoutsRemainValid() {
        #expect(MicrocycleCompactDayLayout.columnCount(itemCount: 0) == 0)
        #expect(MicrocycleCompactDayLayout.rowCount(itemCount: 0) == 0)
    }
}
