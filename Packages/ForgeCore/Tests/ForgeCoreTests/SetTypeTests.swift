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

    @Test func supersetRoundsIgnoreUnevenDropChains() {
        let first = UUID()
        let drop = UUID()
        let second = UUID()
        let withDrop = [
            SupersetSetProgress(id: first, setType: .working, isComplete: true),
            SupersetSetProgress(id: drop, setType: .drop, isComplete: true),
            SupersetSetProgress(id: second, setType: .working, isComplete: true)
        ]
        let siblingFirst = UUID()
        let siblingSecond = UUID()
        let withoutDrop = [
            SupersetSetProgress(id: siblingFirst, setType: .working, isComplete: true),
            SupersetSetProgress(id: siblingSecond, setType: .working, isComplete: false)
        ]

        #expect(SupersetRoundPolicy.logicalRoundIndex(for: first, in: withDrop) == 0)
        #expect(SupersetRoundPolicy.logicalRoundIndex(for: drop, in: withDrop) == 0)
        #expect(SupersetRoundPolicy.logicalRoundIndex(for: second, in: withDrop) == 1)
        #expect(SupersetRoundPolicy.logicalRoundIndex(for: siblingSecond, in: withoutDrop) == 1)
        #expect(SupersetRoundPolicy.isRoundSatisfied(0, in: withDrop))
        #expect(SupersetRoundPolicy.isRoundSatisfied(0, in: withoutDrop))
        #expect(SupersetRoundPolicy.isRoundSatisfied(1, in: withDrop))
        #expect(!SupersetRoundPolicy.isRoundSatisfied(1, in: withoutDrop))
    }

    @Test func supersetRoundWaitsForDropChainAndTreatsMissingRoundAsSatisfied() {
        let base = UUID()
        let pendingDrop = UUID()
        let sets = [
            SupersetSetProgress(id: base, setType: .working, isComplete: true),
            SupersetSetProgress(id: pendingDrop, setType: .drop, isComplete: false)
        ]

        #expect(SupersetRoundPolicy.hasPendingDrop(after: base, in: sets))
        #expect(!SupersetRoundPolicy.isRoundSatisfied(0, in: sets))
        #expect(SupersetRoundPolicy.isRoundSatisfied(1, in: sets))
        #expect(SupersetRoundPolicy.logicalRoundIndex(for: UUID(), in: sets) == nil)
    }
}
