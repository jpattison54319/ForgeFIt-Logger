import Foundation
import Observation
import SwiftUI

/// A model-independent editing session for one ordered routine cycle. Changes
/// stay local until the sheet commits the complete member order in one save.
@MainActor
@Observable
final class RoutineAlternationDraft {
    struct Completion: Equatable, Sendable {
        let endedAt: Date
        let workoutID: UUID
    }

    private(set) var memberIDs: [UUID]

    let originalMemberIDs: [UUID]
    let latestCompletionByMemberID: [UUID: Completion]

    init(
        memberIDs: [UUID],
        latestCompletionByMemberID: [UUID: Completion] = [:]
    ) {
        var seen: Set<UUID> = []
        let canonicalMemberIDs = memberIDs.filter { seen.insert($0).inserted }
        self.memberIDs = canonicalMemberIDs
        self.originalMemberIDs = canonicalMemberIDs
        self.latestCompletionByMemberID = latestCompletionByMemberID
    }

    var hasChanges: Bool {
        memberIDs != originalMemberIDs
    }

    var canSave: Bool {
        memberIDs.count >= 2
    }

    /// The configured successor of the latest completed remaining member is
    /// next. A cycle with no qualifying completion begins at row one.
    var dueMemberID: UUID? {
        guard !memberIDs.isEmpty else { return nil }
        let latest = memberIDs.compactMap { memberID in
            latestCompletionByMemberID[memberID].map { (memberID, $0) }
        }.max { left, right in
            if left.1.endedAt != right.1.endedAt {
                return left.1.endedAt < right.1.endedAt
            }
            return left.1.workoutID.uuidString < right.1.workoutID.uuidString
        }
        guard let latest,
              let completedIndex = memberIDs.firstIndex(of: latest.0) else {
            return memberIDs.first
        }
        return memberIDs[(completedIndex + 1) % memberIDs.count]
    }

    @discardableResult
    func add(_ routineID: UUID) -> Bool {
        guard !memberIDs.contains(routineID) else { return false }
        memberIDs.append(routineID)
        return true
    }

    /// The final member remains as the seed of a new cycle. Existing cycles
    /// intercept a two-to-one removal and use their explicit whole-cycle action.
    @discardableResult
    func remove(_ routineID: UUID) -> Bool {
        guard memberIDs.count > 1,
              let index = memberIDs.firstIndex(of: routineID) else { return false }
        memberIDs.remove(at: index)
        return true
    }

    func move(from offsets: IndexSet, to destination: Int) {
        memberIDs.move(fromOffsets: offsets, toOffset: destination)
    }
}
