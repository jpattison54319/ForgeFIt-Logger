import Foundation
import Testing
@testable import ForgeCore

struct SetTypeTests {

    @Test func selectableExcludesOnlyRetiredRestPause() {
        #expect(!SetType.selectable.contains(.restPause))
        #expect(Set(SetType.selectable) == Set(SetType.allCases).subtracting([.restPause]))
    }

    /// Legacy synced data still decodes — the case is retired from pickers,
    /// not from the enum.
    @Test func restPauseStillDecodesFromRawValue() throws {
        let decoded = try JSONDecoder().decode(SetType.self, from: Data("\"restPause\"".utf8))
        #expect(decoded == .restPause)
    }
}
