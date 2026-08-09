import Foundation
import Observation
import SwiftUI

/// Gesture-local routine-library order. Folder membership and SwiftData
/// positions remain untouched until the continuous reorder gesture ends.
@Observable
final class RoutineReorderSession {
    struct Item: Equatable, Identifiable {
        let id: UUID
        let routineIDs: [UUID]
        let name: String

        init(id: UUID, routineIDs: [UUID], name: String = "Routine") {
            self.id = id
            self.routineIDs = routineIDs
            self.name = name
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

    struct Section {
        let destination: Destination
        let title: String
        let items: [Item]
    }

    enum Placement: Equatable {
        case before(UUID)
        case after(UUID)
        case end
    }

    enum EntryID: Hashable {
        case section(Destination)
        case item(UUID)
    }

    enum Entry: Equatable, Identifiable {
        case section(destination: Destination, title: String)
        case item(Item)

        var id: EntryID {
            switch self {
            case .section(let destination, _): .section(destination)
            case .item(let item): .item(item.id)
            }
        }
    }

    let draggedItemID: UUID
    let originalDestination: Destination
    var fingerGlobalY: CGFloat
    private let sectionOrder: [Destination]
    private let sectionTitles: [Destination: String]
    private let originalOrders: [Destination: [Item]]
    private(set) var orders: [Destination: [Item]]
    private(set) var destination: Destination
    private(set) var didMove = false

    init?(draggedItemID: UUID, fingerGlobalY: CGFloat, sections: [Section]) {
        var sectionOrder: [Destination] = []
        var sectionTitles: [Destination: String] = [:]
        var orders: [Destination: [Item]] = [:]
        for section in sections where orders[section.destination] == nil {
            sectionOrder.append(section.destination)
            sectionTitles[section.destination] = section.title
            orders[section.destination] = section.items
        }
        guard let originalDestination = sectionOrder.first(where: { destination in
            orders[destination, default: []].contains { $0.id == draggedItemID }
        }) else { return nil }

        self.draggedItemID = draggedItemID
        self.originalDestination = originalDestination
        self.fingerGlobalY = fingerGlobalY
        self.sectionOrder = sectionOrder
        self.sectionTitles = sectionTitles
        self.originalOrders = orders
        self.orders = orders
        self.destination = originalDestination
    }

    convenience init?(draggedItemID: UUID, orders: [Destination: [Item]]) {
        self.init(
            draggedItemID: draggedItemID,
            fingerGlobalY: 0,
            sections: orders.map { destination, items in
                Section(destination: destination, title: "", items: items)
            }
        )
    }

    var entries: [Entry] {
        sectionOrder.flatMap { destination in
            [Entry.section(
                destination: destination,
                title: sectionTitles[destination, default: ""]
            )] + orders[destination, default: []].map(Entry.item)
        }
    }

    var hasChanges: Bool {
        orders != originalOrders
    }

    var changedDestinations: Set<Destination> {
        Set(sectionOrder.filter { originalOrders[$0, default: []] != orders[$0, default: []] })
    }

    func items(in destination: Destination) -> [Item] {
        orders[destination, default: []]
    }

    func routineIDs(in destination: Destination) -> [UUID] {
        items(in: destination).flatMap(\.routineIDs)
    }

    func containsRoutine(_ id: UUID) -> Bool {
        draggedItem?.routineIDs.contains(id) == true
    }

    /// Moves through one fixed flat stream of headers and routine slots. The
    /// headers never reorder relative to one another, so slot geometry stays
    /// stable while the held row crosses folder boundaries.
    @discardableResult
    func moveHeld(toFlatIndex index: Int) -> Bool {
        var entries = entries
        guard let current = entries.firstIndex(where: { $0.id == .item(draggedItemID) }),
              entries.count > 1 else { return false }
        let target = min(max(1, index), entries.count - 1)
        guard target != current else { return false }

        entries.move(
            fromOffsets: IndexSet(integer: current),
            toOffset: target > current ? target + 1 : target
        )
        return adopt(entries)
    }

    /// A section header is an explicit first-position target, including when
    /// the destination has no routines yet.
    @discardableResult
    func moveHeldToBeginning(of destination: Destination) -> Bool {
        guard sectionOrder.contains(destination) else { return false }
        if let first = orders[destination, default: []].first,
           first.id != draggedItemID {
            return move(to: destination, placement: .before(first.id))
        }
        if orders[destination, default: []].first?.id == draggedItemID {
            return false
        }
        return move(to: destination, placement: .end)
    }

    @discardableResult
    func move(to destination: Destination, placement: Placement) -> Bool {
        guard sectionOrder.contains(destination), let draggedItem else { return false }
        if case .before(draggedItemID) = placement { return false }
        if case .after(draggedItemID) = placement { return false }

        let previousOrders = orders
        var nextOrders = orders
        for key in sectionOrder {
            nextOrders[key]?.removeAll { $0.id == draggedItemID }
        }

        var destinationItems = nextOrders[destination, default: []]
        let insertionIndex: Int
        switch placement {
        case .before(let targetID):
            insertionIndex = destinationItems.firstIndex { $0.id == targetID } ?? destinationItems.endIndex
        case .after(let targetID):
            insertionIndex = destinationItems.firstIndex { $0.id == targetID }
                .map { destinationItems.index(after: $0) } ?? destinationItems.endIndex
        case .end:
            insertionIndex = destinationItems.endIndex
        }
        destinationItems.insert(draggedItem, at: insertionIndex)
        nextOrders[destination] = destinationItems
        guard nextOrders != previousOrders else { return false }

        orders = nextOrders
        self.destination = destination
        didMove = true
        return true
    }

    private var draggedItem: Item? {
        for destination in sectionOrder {
            if let item = orders[destination, default: []].first(where: { $0.id == draggedItemID }) {
                return item
            }
        }
        return nil
    }

    private func adopt(_ entries: [Entry]) -> Bool {
        var nextOrders = Dictionary(uniqueKeysWithValues: sectionOrder.map { ($0, [Item]()) })
        var currentDestination: Destination?
        for entry in entries {
            switch entry {
            case .section(let destination, _):
                currentDestination = destination
            case .item(let item):
                guard let currentDestination else { return false }
                nextOrders[currentDestination, default: []].append(item)
            }
        }
        guard nextOrders != orders,
              let heldDestination = sectionOrder.first(where: { destination in
                  nextOrders[destination, default: []].contains { $0.id == draggedItemID }
              }) else { return false }

        orders = nextOrders
        destination = heldDestination
        didMove = true
        return true
    }
}
