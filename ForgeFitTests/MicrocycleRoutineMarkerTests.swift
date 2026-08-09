import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

struct MicrocycleRoutineMarkerTests {
    @Test func markersFollowRoutineOrderAndIncludeAlternatingPartner() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let partnerID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let routines = [
            MicrocycleRoutineSnapshot(id: thirdID, name: "Conditioning", position: 30),
            MicrocycleRoutineSnapshot(
                id: secondID,
                name: "Lower",
                position: 20,
                alternateRoutineID: partnerID,
                alternateRoutineName: "Lower B"
            ),
            MicrocycleRoutineSnapshot(id: firstID, name: "Upper", position: 10)
        ]

        let markers = MicrocycleRoutineMarker.markersByRoutineID(in: routines)

        #expect(markers[firstID] == "A")
        #expect(markers[secondID] == "B")
        #expect(markers[partnerID] == "B")
        #expect(markers[thirdID] == "C")
        #expect(MicrocycleRoutineMarker.markers(
            for: [thirdID, partnerID],
            in: routines
        ) == ["B", "C"])
    }

    @Test func markersContinueAfterZ() {
        #expect(MicrocycleRoutineMarker.marker(for: 0) == "A")
        #expect(MicrocycleRoutineMarker.marker(for: 25) == "Z")
        #expect(MicrocycleRoutineMarker.marker(for: 26) == "AA")
        #expect(MicrocycleRoutineMarker.marker(for: 27) == "AB")
    }
}
