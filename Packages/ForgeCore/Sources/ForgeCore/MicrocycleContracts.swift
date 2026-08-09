import Foundation

/// One workout template expected during a microcycle window.
///
/// The name and position are frozen when the window begins so reorganizing
/// the routine library cannot rewrite what an earlier window expected.
public struct MicrocycleRoutineSnapshot: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let position: Int

    public init(id: UUID, name: String, position: Int) {
        self.id = id
        self.name = name
        self.position = position
    }
}

/// A reversible, microcycle-only placement of an existing completed workout.
///
/// The workout's real `startedAt` remains untouched. `day` is the calendar day
/// where the user wants that workout credited inside this tracking run.
public struct MicrocycleDayAssignment: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let day: Date
    public let workoutID: UUID
    public let assignedAt: Date

    public init(
        id: UUID = UUID(),
        day: Date,
        workoutID: UUID,
        assignedAt: Date = .now
    ) {
        self.id = id
        self.day = day
        self.workoutID = workoutID
        self.assignedAt = assignedAt
    }
}

/// The smallest workout evidence needed to evaluate microcycle completion.
public struct MicrocycleWorkoutEvidence: Equatable, Sendable {
    public let id: UUID
    public let routineID: UUID?
    public let startedAt: Date
    public let isCompleted: Bool
    public let isDeleted: Bool

    public init(
        id: UUID,
        routineID: UUID?,
        startedAt: Date,
        isCompleted: Bool,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.routineID = routineID
        self.startedAt = startedAt
        self.isCompleted = isCompleted
        self.isDeleted = isDeleted
    }
}

public struct MicrocycleWindow: Equatable, Sendable {
    public let index: Int
    public let startsAt: Date
    public let endsAt: Date

    public init(index: Int, startsAt: Date, endsAt: Date) {
        self.index = index
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    public func contains(_ date: Date) -> Bool {
        date >= startsAt && date < endsAt
    }
}

public struct MicrocycleRoutineProgress: Equatable, Identifiable, Sendable {
    public let routine: MicrocycleRoutineSnapshot
    public let workoutID: UUID?
    public let completedAt: Date?

    public var id: UUID { routine.id }
    public var isCompleted: Bool { workoutID != nil }

    public init(
        routine: MicrocycleRoutineSnapshot,
        workoutID: UUID?,
        completedAt: Date?
    ) {
        self.routine = routine
        self.workoutID = workoutID
        self.completedAt = completedAt
    }
}

public struct MicrocycleProgress: Equatable, Sendable {
    public let window: MicrocycleWindow
    public let routines: [MicrocycleRoutineProgress]

    public var completedCount: Int { routines.count(where: \.isCompleted) }
    public var requiredCount: Int { routines.count }
    public var isComplete: Bool { requiredCount > 0 && completedCount == requiredCount }

    public init(window: MicrocycleWindow, routines: [MicrocycleRoutineProgress]) {
        self.window = window
        self.routines = routines
    }
}
