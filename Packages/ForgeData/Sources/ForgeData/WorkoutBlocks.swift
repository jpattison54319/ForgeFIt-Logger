import Foundation
import SwiftData

public enum WorkoutBlockKind: String, Codable, CaseIterable, Sendable {
    case conditioning
    case yoga

    public var title: String {
        switch self {
        case .conditioning: "Conditioning"
        case .yoga: "Yoga"
        }
    }
}

/// CloudKit-safe, user-authored plan block that shares the routine's visible
/// ordering space with ordinary exercise rows.
@Model
public final class RoutineBlockModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var kindRaw: String = WorkoutBlockKind.conditioning.rawValue
    public var position: Int = 0
    public var planJSON: String?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var routine: RoutineModel?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        kind: WorkoutBlockKind,
        position: Int = 0,
        planJSON: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.kindRaw = kind.rawValue
        self.position = position
        self.planJSON = planJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kind: WorkoutBlockKind {
        get { WorkoutBlockKind(rawValue: kindRaw) ?? .conditioning }
        set { kindRaw = newValue.rawValue }
    }
}

/// Local-only executed block. Every block freezes its own plan and owns its
/// progress/result, allowing multiple independent blocks in one workout.
@Model
public final class WorkoutBlockModel {
    public var id: UUID = UUID()
    public var userID: UUID = UUID()
    public var kindRaw: String = WorkoutBlockKind.conditioning.rawValue
    public var position: Int = 0
    public var planSnapshotJSON: String?
    public var progressJSON: String?
    public var resultJSON: String?
    public var sourceRoutineBlockID: UUID?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var workout: WorkoutModel?

    public init(
        id: UUID = UUID(),
        userID: UUID,
        kind: WorkoutBlockKind,
        position: Int = 0,
        planSnapshotJSON: String? = nil,
        progressJSON: String? = nil,
        resultJSON: String? = nil,
        sourceRoutineBlockID: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userID = userID
        self.kindRaw = kind.rawValue
        self.position = position
        self.planSnapshotJSON = planSnapshotJSON
        self.progressJSON = progressJSON
        self.resultJSON = resultJSON
        self.sourceRoutineBlockID = sourceRoutineBlockID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var kind: WorkoutBlockKind {
        get { WorkoutBlockKind(rawValue: kindRaw) ?? .conditioning }
        set { kindRaw = newValue.rawValue }
    }
}

public enum OrderedRoutineItem: Identifiable {
    case exercise(RoutineExerciseModel)
    case block(RoutineBlockModel)

    public var id: UUID {
        switch self {
        case .exercise(let exercise): exercise.id
        case .block(let block): block.id
        }
    }

    public var position: Int {
        get {
            switch self {
            case .exercise(let exercise): exercise.position
            case .block(let block): block.position
            }
        }
        nonmutating set {
            switch self {
            case .exercise(let exercise): exercise.position = newValue
            case .block(let block): block.position = newValue
            }
        }
    }

    public static func ordered(in routine: RoutineModel) -> [Self] {
        (routine.exercises.map(Self.exercise) + routine.blocks.map(Self.block))
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
}

public enum OrderedWorkoutItem: Identifiable {
    case exercise(WorkoutExerciseModel)
    case block(WorkoutBlockModel)

    public var id: UUID {
        switch self {
        case .exercise(let exercise): exercise.id
        case .block(let block): block.id
        }
    }

    public var position: Int {
        get {
            switch self {
            case .exercise(let exercise): exercise.position
            case .block(let block): block.position
            }
        }
        nonmutating set {
            switch self {
            case .exercise(let exercise): exercise.position = newValue
            case .block(let block): block.position = newValue
            }
        }
    }

    public static func ordered(in workout: WorkoutModel) -> [Self] {
        let visibleExercises = workout.exercises.filter { $0.generatedByWorkoutBlockID == nil }
        return (visibleExercises.map(Self.exercise) + workout.blocks.map(Self.block))
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
}
