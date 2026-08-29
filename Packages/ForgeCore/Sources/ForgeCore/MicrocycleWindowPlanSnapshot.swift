import Foundation

/// One rest slot inserted into a tracked microcycle's workout order.
///
/// `position` is the item's index in the combined workout/rest sequence. The
/// folder remains the authority for workout order; only rest slots are movable.
public struct MicrocyclePlannedRestDaySnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let position: Int
    public let completedRestDayID: UUID?
    public let completedAt: Date?

    public init(
        id: UUID = UUID(),
        position: Int,
        completedRestDayID: UUID? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.position = position
        self.completedRestDayID = completedRestDayID
        self.completedAt = completedAt
    }

    public func positioned(at position: Int) -> MicrocyclePlannedRestDaySnapshot {
        .init(
            id: id,
            position: position,
            completedRestDayID: completedRestDayID,
            completedAt: completedAt
        )
    }

    public func completing(
        with restDayID: UUID,
        at date: Date
    ) -> MicrocyclePlannedRestDaySnapshot {
        .init(
            id: id,
            position: position,
            completedRestDayID: restDayID,
            completedAt: date
        )
    }

    public func resettingCompletion() -> MicrocyclePlannedRestDaySnapshot {
        .init(id: id, position: position)
    }
}

public enum MicrocyclePlanItemSnapshot: Equatable, Hashable, Identifiable, Sendable {
    case routine(MicrocycleRoutineSnapshot)
    case restDay(MicrocyclePlannedRestDaySnapshot)

    public var id: UUID {
        switch self {
        case .routine(let routine): routine.id
        case .restDay(let restDay): restDay.id
        }
    }

    public var isRestDay: Bool {
        if case .restDay = self { true } else { false }
    }
}

/// Backward-compatible payload stored in `MicrocycleWindowModel.routineSnapshotJSON`.
/// Legacy JSON arrays decode as routine-only plans.
public struct MicrocycleWindowPlanSnapshot: Codable, Equatable, Sendable {
    public let routines: [MicrocycleRoutineSnapshot]
    public let plannedRestDays: [MicrocyclePlannedRestDaySnapshot]

    public init(
        routines: [MicrocycleRoutineSnapshot],
        plannedRestDays: [MicrocyclePlannedRestDaySnapshot] = []
    ) {
        self.routines = routines
        self.plannedRestDays = plannedRestDays
    }

    public var orderedItems: [MicrocyclePlanItemSnapshot] {
        var items = routines
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map(MicrocyclePlanItemSnapshot.routine)

        for restDay in plannedRestDays.sorted(by: Self.restDayOrder) {
            let position = min(max(restDay.position, 0), items.count)
            items.insert(.restDay(restDay), at: position)
        }
        return items
    }

    public func replacingRoutines(
        _ routines: [MicrocycleRoutineSnapshot]
    ) -> MicrocycleWindowPlanSnapshot {
        Self(routines: routines, plannedRestDays: plannedRestDays).normalized()
    }

    public func addingRestDay(id: UUID = UUID()) -> MicrocycleWindowPlanSnapshot {
        var items = orderedItems
        items.append(.restDay(.init(id: id, position: items.count)))
        return rebuildingRestPositions(from: items)
    }

    public func movingRestDay(
        id: UUID,
        to targetIndex: Int
    ) -> MicrocycleWindowPlanSnapshot {
        var items = orderedItems
        guard let sourceIndex = items.firstIndex(where: { item in
            if case .restDay(let restDay) = item { return restDay.id == id }
            return false
        }) else { return self }

        let moved = items.remove(at: sourceIndex)
        let destination = min(max(targetIndex, 0), items.count)
        items.insert(moved, at: destination)
        return rebuildingRestPositions(from: items)
    }

    public func removingRestDay(id: UUID) -> MicrocycleWindowPlanSnapshot {
        rebuildingRestPositions(from: orderedItems.filter { item in
            if case .restDay(let restDay) = item { return restDay.id != id }
            return true
        })
    }

    public func completingRestDay(
        id: UUID,
        with restDayID: UUID,
        at date: Date
    ) -> MicrocycleWindowPlanSnapshot {
        let rests = plannedRestDays.map {
            $0.id == id ? $0.completing(with: restDayID, at: date) : $0
        }
        return Self(routines: routines, plannedRestDays: rests).normalized()
    }

    public func resettingRestDayCompletions() -> MicrocycleWindowPlanSnapshot {
        Self(
            routines: routines,
            plannedRestDays: plannedRestDays.map { $0.resettingCompletion() }
        ).normalized()
    }

    public func normalized() -> MicrocycleWindowPlanSnapshot {
        rebuildingRestPositions(from: orderedItems)
    }

    public static func decode(from json: String) -> MicrocycleWindowPlanSnapshot {
        guard let data = json.data(using: .utf8) else { return .init(routines: []) }
        if let plan = try? JSONDecoder().decode(Self.self, from: data) {
            return plan.normalized()
        }
        let legacy = (try? JSONDecoder().decode([MicrocycleRoutineSnapshot].self, from: data)) ?? []
        return .init(routines: legacy)
    }

    public func encodedJSON() -> String? {
        let normalized = normalized()
        let data: Data?
        if normalized.plannedRestDays.isEmpty {
            data = try? JSONEncoder().encode(normalized.routines)
        } else {
            data = try? JSONEncoder().encode(normalized)
        }
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func restDayOrder(
        _ lhs: MicrocyclePlannedRestDaySnapshot,
        _ rhs: MicrocyclePlannedRestDaySnapshot
    ) -> Bool {
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func rebuildingRestPositions(
        from items: [MicrocyclePlanItemSnapshot]
    ) -> MicrocycleWindowPlanSnapshot {
        let rests = items.enumerated().compactMap { index, item in
            if case .restDay(let restDay) = item {
                return restDay.positioned(at: index)
            }
            return nil
        }
        return .init(routines: routines, plannedRestDays: rests)
    }
}
