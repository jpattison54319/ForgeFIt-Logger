import Foundation
import Testing
import ForgeData
@testable import ForgeFit

/// Superset grouping for the full-length share image. A shared workout that
/// drops the pairing misreports the session — alternating two lifts is not
/// the same training as doing them straight through.
@MainActor
struct ShareLogEntryTests {

    private let userID = UUID()

    private func exercise(_ position: Int, superset: Int? = nil) -> WorkoutExerciseModel {
        let we = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), position: position)
        we.supersetGroup = superset
        return we
    }

    private func kinds(_ entries: [ShareLogEntry]) -> [String] {
        entries.map {
            switch $0 {
            case .single: "single"
            case .superset(let group, let members): "ss\(group)x\(members.count)"
            }
        }
    }

    @Test func consecutiveSameGroupExercisesBecomeOneSupersetEntry() {
        let entries = ShareLogEntry.entries(for: [
            exercise(0),
            exercise(1, superset: 0),
            exercise(2, superset: 0),
            exercise(3),
        ])
        #expect(kinds(entries) == ["single", "ss0x2", "single"])
    }

    @Test func adjacentDistinctGroupsDoNotMerge() {
        let entries = ShareLogEntry.entries(for: [
            exercise(0, superset: 0),
            exercise(1, superset: 0),
            exercise(2, superset: 1),
            exercise(3, superset: 1),
        ])
        #expect(kinds(entries) == ["ss0x2", "ss1x2"])
    }

    @Test func loneGroupMemberStaysStandalone() {
        // A one-exercise "superset" container would be visual noise; the
        // badge beside the name still states the group truthfully.
        let entries = ShareLogEntry.entries(for: [exercise(0, superset: 0), exercise(1)])
        #expect(kinds(entries) == ["single", "single"])
    }

    @Test func nonAdjacentMembersOfTheSameGroupDoNotReorderTheLog() {
        // Logged order is the source of truth — the card must not hoist a
        // stray member up to its partners. Each still carries its badge.
        let entries = ShareLogEntry.entries(for: [
            exercise(0, superset: 0),
            exercise(1, superset: 0),
            exercise(2),
            exercise(3, superset: 0),
        ])
        #expect(kinds(entries) == ["ss0x2", "single", "single"])
    }

    @Test func tripleSupersetGroupsTogether() {
        let entries = ShareLogEntry.entries(for: [
            exercise(0, superset: 2),
            exercise(1, superset: 2),
            exercise(2, superset: 2),
        ])
        #expect(kinds(entries) == ["ss2x3"])
    }

    @Test func everyExerciseSurvivesGrouping() {
        // No exercise may be dropped by segmentation — the log is complete
        // or it isn't a faithful capture.
        let input = [
            exercise(0), exercise(1, superset: 0), exercise(2, superset: 0),
            exercise(3, superset: 1), exercise(4), exercise(5, superset: 3),
        ]
        let flattened = ShareLogEntry.entries(for: input).flatMap { entry -> [WorkoutExerciseModel] in
            switch entry {
            case .single(let we): [we]
            case .superset(_, let members): members
            }
        }
        #expect(flattened.map(\.id) == input.map(\.id))
    }

    @Test func emptyWorkoutProducesNoEntries() {
        #expect(ShareLogEntry.entries(for: []).isEmpty)
    }
}
