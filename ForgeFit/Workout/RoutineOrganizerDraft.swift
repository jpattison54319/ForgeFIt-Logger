import ForgeData
import Foundation
import Observation
import SwiftUI

/// A complete, model-independent routine-library draft. Editing this value
/// never changes SwiftData, so several organization decisions can be reviewed
/// together and either committed once or discarded as a unit.
@MainActor
@Observable
final class RoutineOrganizerDraft {
    enum EntryID: Hashable {
        case ungrouped
        case folder(UUID)
        case routine(UUID)
    }

    enum EntryKind: Equatable {
        case ungrouped(count: Int)
        case folder(id: UUID, parentID: UUID?, depth: Int)
        case routine(item: RoutineItem, destination: Destination, depth: Int)
    }

    struct Entry: Identifiable, Equatable {
        let id: EntryID
        let kind: EntryKind

        var isMovable: Bool {
            if case .ungrouped = kind { false } else { true }
        }
    }

    enum Destination: Hashable {
        case ungrouped
        case folder(UUID)

        var folderID: UUID? {
            switch self {
            case .ungrouped: nil
            case .folder(let id): id
            }
        }
    }

    struct RoutineItem: Identifiable, Equatable {
        let id: UUID
        let routineIDs: [UUID]
        let name: String
    }

    struct Snapshot: Equatable {
        var rootFolderIDs: [UUID]
        var childFolderIDs: [UUID: [UUID]]
        var routineItems: [Destination: [RoutineItem]]
    }

    private(set) var snapshot: Snapshot
    let original: Snapshot
    let folderNames: [UUID: String]
    let originalFolderUpdatedAt: [UUID: Date]
    let originalRoutineUpdatedAt: [UUID: Date]

    init(
        folders: [RoutineFolderModel],
        routines: [RoutineModel],
        alternationStates: [RoutineAlternationService.State] = []
    ) {
        let routines = RoutineDeduplicator.canonicalRoutines(routines)
        let sortedFolders = folders.sorted(by: Self.folderSort)
        let roots = sortedFolders.filter { $0.parentID == nil }.map(\.id)
        var children: [UUID: [UUID]] = [:]
        for rootID in roots {
            children[rootID] = sortedFolders.filter { $0.parentID == rootID }.map(\.id)
        }

        let sortedRoutines = routines.sorted(by: Self.routineSort)
        let folderIDs = Set(sortedFolders.map(\.id))
        var items: [Destination: [RoutineItem]] = [:]
        items[.ungrouped] = Self.makeRoutineItems(
            from: sortedRoutines.filter { $0.folderID == nil },
            alternationStates: alternationStates
        )
        for folderID in folderIDs {
            items[.folder(folderID)] = Self.makeRoutineItems(
                from: sortedRoutines.filter { $0.folderID == folderID },
                alternationStates: alternationStates
            )
        }

        let initial = Snapshot(
            rootFolderIDs: roots,
            childFolderIDs: children,
            routineItems: items
        )
        snapshot = initial
        original = initial
        folderNames = Dictionary(uniqueKeysWithValues: sortedFolders.map { ($0.id, $0.name) })
        originalFolderUpdatedAt = Dictionary(uniqueKeysWithValues: sortedFolders.map { ($0.id, $0.updatedAt) })
        originalRoutineUpdatedAt = Dictionary(uniqueKeysWithValues: sortedRoutines.map { ($0.id, $0.updatedAt) })
    }

    var hasChanges: Bool { snapshot != original }
    var rootFolderIDs: [UUID] { snapshot.rootFolderIDs }

    var routineDestinations: [Destination] {
        [.ungrouped] + leafFolderIDs.map(Destination.folder)
    }

    /// The organizer mirrors the Workout screen's hierarchy in one compact
    /// stream so a native move can cross routine and folder boundaries.
    var entries: [Entry] {
        var result = [Entry(
            id: .ungrouped,
            kind: .ungrouped(count: routines(in: .ungrouped).count)
        )]
        result += routines(in: .ungrouped).map {
            Entry(
                id: .routine($0.id),
                kind: .routine(item: $0, destination: .ungrouped, depth: 1)
            )
        }

        for rootID in rootFolderIDs {
            result.append(Entry(
                id: .folder(rootID),
                kind: .folder(id: rootID, parentID: nil, depth: 0)
            ))
            let childIDs = children(of: rootID)
            if childIDs.isEmpty {
                result += routineEntries(in: .folder(rootID), depth: 1)
            } else {
                for childID in childIDs {
                    result.append(Entry(
                        id: .folder(childID),
                        kind: .folder(id: childID, parentID: rootID, depth: 1)
                    ))
                    result += routineEntries(in: .folder(childID), depth: 2)
                }
            }
        }
        return result
    }

    var canOrganize: Bool {
        if rootFolderIDs.count > 1 { return true }
        if snapshot.childFolderIDs.values.contains(where: { $0.count > 1 }) { return true }
        if snapshot.routineItems.values.contains(where: { $0.count > 1 }) { return true }
        if routineDestinations.count > 1,
           snapshot.routineItems.values.contains(where: { !$0.isEmpty }) { return true }
        return allFolderIDs.contains { !validParents(for: $0).isEmpty || parentID(of: $0) != nil }
    }

    var allFolderIDs: [UUID] {
        rootFolderIDs + rootFolderIDs.flatMap(children)
    }

    var allRoutineIDs: [UUID] {
        routineDestinations.flatMap { routines(in: $0).flatMap(\.routineIDs) }
    }

    func children(of folderID: UUID) -> [UUID] {
        snapshot.childFolderIDs[folderID, default: []]
    }

    func parentID(of folderID: UUID) -> UUID? {
        snapshot.childFolderIDs.first(where: { $0.value.contains(folderID) })?.key
    }

    func originalParentID(of folderID: UUID) -> UUID? {
        original.childFolderIDs.first(where: { $0.value.contains(folderID) })?.key
    }

    func isLeaf(_ folderID: UUID) -> Bool {
        children(of: folderID).isEmpty
    }

    func routines(in destination: Destination) -> [RoutineItem] {
        snapshot.routineItems[destination, default: []]
    }

    func contentCount(for folderID: UUID) -> Int {
        let childIDs = children(of: folderID)
        return childIDs.isEmpty ? routines(in: .folder(folderID)).count : childIDs.count
    }

    func destinationLabel(_ destination: Destination) -> String {
        switch destination {
        case .ungrouped:
            return "Ungrouped"
        case .folder(let folderID):
            let name = folderNames[folderID, default: "Folder"]
            guard let parentID = parentID(of: folderID) else { return name }
            return "\(folderNames[parentID, default: "Folder"]) / \(name)"
        }
    }

    @discardableResult
    func moveEntries(from offsets: IndexSet, to destination: Int) -> Bool {
        guard offsets.count == 1,
              let sourceIndex = offsets.first,
              entries.indices.contains(sourceIndex) else { return false }
        let source = entries[sourceIndex]
        guard source.isMovable else { return false }

        var proposed = entries
        proposed.move(fromOffsets: offsets, toOffset: destination)
        guard let proposedIndex = proposed.firstIndex(where: { $0.id == source.id }) else {
            return false
        }

        switch source.kind {
        case .routine(let item, _, _):
            return moveRoutine(item.id, using: proposed, at: proposedIndex)
        case .folder(let folderID, _, _):
            return moveFolder(folderID, using: proposed)
        case .ungrouped:
            return false
        }
    }

    @discardableResult
    func moveRoutine(_ itemID: UUID, to destination: Destination) -> Bool {
        moveRoutine(itemID, to: destination, before: nil)
    }

    @discardableResult
    func moveRoutine(
        _ itemID: UUID,
        to destination: Destination,
        before nextItemID: UUID?
    ) -> Bool {
        guard destination.folderID.map(isLeaf) ?? true,
              let source = routineDestinations.first(where: {
                  routines(in: $0).contains { $0.id == itemID }
              }),
              let item = routines(in: source).first(where: { $0.id == itemID }) else {
            return false
        }
        let previous = snapshot
        snapshot.routineItems[source]?.removeAll { $0.id == itemID }
        var destinationItems = snapshot.routineItems[destination, default: []]
        let insertionIndex = nextItemID.flatMap { nextID in
            destinationItems.firstIndex { $0.id == nextID }
        } ?? destinationItems.endIndex
        destinationItems.insert(item, at: insertionIndex)
        snapshot.routineItems[destination] = destinationItems
        return snapshot != previous
    }

    /// Membership changes never move routines implicitly. A routine-holding
    /// folder becomes a valid parent only after its routines are moved out in
    /// this same draft.
    func validParents(for folderID: UUID) -> [UUID] {
        guard isLeaf(folderID) else { return [] }
        return rootFolderIDs.filter { candidateID in
            candidateID != folderID
                && parentID(of: folderID) != candidateID
                && routines(in: .folder(candidateID)).isEmpty
        }
    }

    @discardableResult
    func moveFolder(_ folderID: UUID, to parentID: UUID?) -> Bool {
        moveFolder(folderID, to: parentID, before: nil)
    }

    @discardableResult
    func moveFolder(
        _ folderID: UUID,
        to parentID: UUID?,
        before nextFolderID: UUID?
    ) -> Bool {
        if !isLeaf(folderID), parentID != nil { return false }
        if let parentID {
            guard parentID != folderID,
                  self.parentID(of: parentID) == nil,
                  routines(in: .folder(parentID)).isEmpty else { return false }
        }

        let previous = snapshot
        snapshot.rootFolderIDs.removeAll { $0 == folderID }
        for key in Array(snapshot.childFolderIDs.keys) {
            snapshot.childFolderIDs[key]?.removeAll { $0 == folderID }
        }
        if let parentID {
            var childIDs = snapshot.childFolderIDs[parentID, default: []]
            let insertionIndex = nextFolderID.flatMap { childIDs.firstIndex(of: $0) }
                ?? childIDs.endIndex
            childIDs.insert(folderID, at: insertionIndex)
            snapshot.childFolderIDs[parentID] = childIDs
        } else {
            let insertionIndex = nextFolderID.flatMap { snapshot.rootFolderIDs.firstIndex(of: $0) }
                ?? snapshot.rootFolderIDs.endIndex
            snapshot.rootFolderIDs.insert(folderID, at: insertionIndex)
        }
        return snapshot != previous
    }

    private var leafFolderIDs: [UUID] {
        rootFolderIDs.flatMap { rootID in
            let childIDs = children(of: rootID)
            return childIDs.isEmpty ? [rootID] : childIDs
        }
    }

    private func routineEntries(in destination: Destination, depth: Int) -> [Entry] {
        routines(in: destination).map {
            Entry(
                id: .routine($0.id),
                kind: .routine(item: $0, destination: destination, depth: depth)
            )
        }
    }

    private func moveRoutine(
        _ itemID: UUID,
        using proposed: [Entry],
        at proposedIndex: Int
    ) -> Bool {
        let preceding = proposed[..<proposedIndex].last
        let destination: Destination
        switch preceding?.kind {
        case .none, .some(.ungrouped):
            destination = .ungrouped
        case .some(.routine(_, let owner, _)):
            destination = owner
        case .some(.folder(let folderID, _, _)) where isLeaf(folderID):
            destination = .folder(folderID)
        default:
            return false
        }

        let nextItemID = proposed.dropFirst(proposedIndex + 1).first { entry in
            if case .routine(_, let owner, _) = entry.kind {
                return owner == destination
            }
            return false
        }.flatMap { entry -> UUID? in
            if case .routine(let item, _, _) = entry.kind { item.id } else { nil }
        }
        return moveRoutine(itemID, to: destination, before: nextItemID)
    }

    private func moveFolder(_ folderID: UUID, using proposed: [Entry]) -> Bool {
        let excludedIDs = Set(entries.compactMap { entry -> EntryID? in
            switch entry.kind {
            case .routine(_, .folder(let ownerID), _) where ownerID == folderID:
                return entry.id
            case .folder(let childID, let parentID, _) where parentID == folderID:
                return .folder(childID)
            case .routine(_, .folder(let ownerID), _) where parentID(of: ownerID) == folderID:
                return entry.id
            default:
                return nil
            }
        })
        let context = proposed.filter { $0.id == .folder(folderID) || !excludedIDs.contains($0.id) }
        guard let movedIndex = context.firstIndex(where: { $0.id == .folder(folderID) }) else {
            return false
        }
        let next = context.indices.contains(movedIndex + 1) ? context[movedIndex + 1] : nil

        switch next?.kind {
        case .none:
            return moveFolder(folderID, to: nil, before: nil)
        case .some(.ungrouped):
            return moveFolder(folderID, to: nil, before: rootFolderIDs.first)
        case .some(.folder(let nextID, let targetParentID, _)):
            return moveFolder(folderID, to: targetParentID, before: nextID)
        case .some(.routine(_, .ungrouped, _)):
            return moveFolder(folderID, to: nil, before: rootFolderIDs.first)
        case .some(.routine(_, .folder(let ownerID), _)):
            let targetParentID = parentID(of: ownerID)
            return moveFolder(folderID, to: targetParentID, before: ownerID)
        }
    }

    private static func makeRoutineItems(
        from routines: [RoutineModel],
        alternationStates: [RoutineAlternationService.State]
    ) -> [RoutineItem] {
        let routineIDs = Set(routines.map(\.id))
        let states = alternationStates.filter {
            routineIDs.contains($0.owner.id) && routineIDs.contains($0.partner.id)
        }
        var statesByOwner: [UUID: RoutineAlternationService.State] = [:]
        for state in states where statesByOwner[state.owner.id] == nil {
            statesByOwner[state.owner.id] = state
        }
        let partnerIDs = Set(states.map { $0.partner.id })

        return routines.compactMap { routine in
            if partnerIDs.contains(routine.id) { return nil }
            guard let state = statesByOwner[routine.id] else {
                return RoutineItem(id: routine.id, routineIDs: [routine.id], name: routine.name)
            }
            let pairIDs = Set([state.owner.id, state.partner.id])
            return RoutineItem(
                id: state.owner.id,
                routineIDs: routines.filter { pairIDs.contains($0.id) }.map(\.id),
                name: "\(state.owner.name) / \(state.partner.name)"
            )
        }
    }

    private static func folderSort(_ lhs: RoutineFolderModel, _ rhs: RoutineFolderModel) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.name != rhs.name {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func routineSort(_ lhs: RoutineModel, _ rhs: RoutineModel) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
