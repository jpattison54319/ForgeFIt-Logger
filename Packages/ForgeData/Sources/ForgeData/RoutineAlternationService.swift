import Foundation
import SwiftData

/// Deterministic pairing and next-member resolution for alternating routines.
/// Pair configuration syncs as plan data; the due member is deliberately
/// derived from completed local workouts so no mutable cursor can drift from
/// the user's actual training history.
@MainActor
public enum RoutineAlternationService {
    public enum ServiceError: LocalizedError, Equatable {
        case sameRoutine
        case unavailableRoutine
        case alreadyPaired

        public var errorDescription: String? {
            switch self {
            case .sameRoutine:
                "Choose a different routine."
            case .unavailableRoutine:
                "Both routines must be available."
            case .alreadyPaired:
                "One of these routines already has an alternating routine."
            }
        }
    }

    public struct State {
        public let alternation: RoutineAlternationModel
        public let owner: RoutineModel
        public let partner: RoutineModel
        public let due: RoutineModel

        public var other: RoutineModel {
            due.id == owner.id ? partner : owner
        }

        public init(
            alternation: RoutineAlternationModel,
            owner: RoutineModel,
            partner: RoutineModel,
            due: RoutineModel
        ) {
            self.alternation = alternation
            self.owner = owner
            self.partner = partner
            self.due = due
        }
    }

    public static func live(_ alternations: [RoutineAlternationModel]) -> [RoutineAlternationModel] {
        alternations
            .filter { $0.deletedAt == nil }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString > $1.id.uuidString
            }
    }

    public static func alternation(
        containing routineID: UUID,
        in alternations: [RoutineAlternationModel]
    ) -> RoutineAlternationModel? {
        live(alternations).first {
            $0.ownerRoutineID == routineID || $0.partnerRoutineID == routineID
        }
    }

    public static func state(
        for alternation: RoutineAlternationModel,
        routines: [RoutineModel],
        workouts: [WorkoutModel]
    ) -> State? {
        guard alternation.deletedAt == nil,
              alternation.ownerRoutineID != alternation.partnerRoutineID,
              let owner = liveRoutine(id: alternation.ownerRoutineID, in: routines),
              let partner = liveRoutine(id: alternation.partnerRoutineID, in: routines) else {
            return nil
        }
        let dueID = dueRoutineID(for: alternation, workouts: workouts)
        return State(
            alternation: alternation,
            owner: owner,
            partner: partner,
            due: dueID == partner.id ? partner : owner
        )
    }

    public static func state(
        containing routineID: UUID,
        alternations: [RoutineAlternationModel],
        routines: [RoutineModel],
        workouts: [WorkoutModel]
    ) -> State? {
        states(alternations: alternations, routines: routines, workouts: workouts).first {
            $0.owner.id == routineID || $0.partner.id == routineID
        }
    }

    /// Resolves a CloudKit-safe set of pairs. Concurrent edits on two devices
    /// can briefly deliver overlapping records; newest wins and every routine
    /// participates at most once until tombstones converge.
    public static func states(
        alternations: [RoutineAlternationModel],
        routines: [RoutineModel],
        workouts: [WorkoutModel]
    ) -> [State] {
        var claimedRoutineIDs: Set<UUID> = []
        return live(alternations).compactMap { alternation in
            guard let state = state(for: alternation, routines: routines, workouts: workouts),
                  !claimedRoutineIDs.contains(state.owner.id),
                  !claimedRoutineIDs.contains(state.partner.id) else { return nil }
            claimedRoutineIDs.insert(state.owner.id)
            claimedRoutineIDs.insert(state.partner.id)
            return state
        }
    }

    public static func dueRoutineID(
        for alternation: RoutineAlternationModel,
        workouts: [WorkoutModel]
    ) -> UUID {
        let memberIDs = Set([alternation.ownerRoutineID, alternation.partnerRoutineID])
        let latest = workouts
            .filter {
                $0.deletedAt == nil
                    && $0.endedAt != nil
                    && ($0.endedAt ?? .distantPast) >= alternation.createdAt
                    && $0.routineID.map(memberIDs.contains) == true
            }
            .max {
                let lhsEnd = $0.endedAt ?? .distantPast
                let rhsEnd = $1.endedAt ?? .distantPast
                if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                return $0.id.uuidString < $1.id.uuidString
            }
        return latest?.routineID == alternation.ownerRoutineID
            ? alternation.partnerRoutineID
            : alternation.ownerRoutineID
    }

    @discardableResult
    public static func create(
        owner: RoutineModel,
        partner: RoutineModel,
        in context: ModelContext,
        now: Date = .now,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws -> RoutineAlternationModel {
        guard owner.id != partner.id else { throw ServiceError.sameRoutine }
        guard isLive(owner), isLive(partner) else { throw ServiceError.unavailableRoutine }
        let existing = try context.fetch(FetchDescriptor<RoutineAlternationModel>())
        guard alternation(containing: owner.id, in: existing) == nil,
              alternation(containing: partner.id, in: existing) == nil else {
            throw ServiceError.alreadyPaired
        }
        let alternation = RoutineAlternationModel(
            userID: owner.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            createdAt: now,
            updatedAt: now
        )
        context.insert(alternation)
        do {
            try save(context)
        } catch {
            context.delete(alternation)
            throw error
        }
        return alternation
    }

    public static func remove(
        _ alternation: RoutineAlternationModel,
        in context: ModelContext,
        now: Date = .now,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let previousDeletedAt = alternation.deletedAt
        let previousUpdatedAt = alternation.updatedAt
        alternation.deletedAt = now
        alternation.updatedAt = now
        do {
            try save(context)
        } catch {
            alternation.deletedAt = previousDeletedAt
            alternation.updatedAt = previousUpdatedAt
            throw error
        }
    }

    public static func removeAll(
        containing routineID: UUID,
        in context: ModelContext,
        now: Date = .now,
        saveChanges: Bool = true,
        save: @MainActor (ModelContext) throws -> Void = { try $0.save() }
    ) throws {
        let matches = live(try context.fetch(FetchDescriptor<RoutineAlternationModel>()))
            .filter { $0.ownerRoutineID == routineID || $0.partnerRoutineID == routineID }
        let snapshots = matches.map {
            (alternation: $0, deletedAt: $0.deletedAt, updatedAt: $0.updatedAt)
        }
        for alternation in matches {
            alternation.deletedAt = now
            alternation.updatedAt = now
        }
        guard saveChanges, !matches.isEmpty else { return }
        do {
            try save(context)
        } catch {
            for snapshot in snapshots {
                snapshot.alternation.deletedAt = snapshot.deletedAt
                snapshot.alternation.updatedAt = snapshot.updatedAt
            }
            throw error
        }
    }

    private static func liveRoutine(id: UUID, in routines: [RoutineModel]) -> RoutineModel? {
        routines.first { $0.id == id && isLive($0) }
    }

    private static func isLive(_ routine: RoutineModel) -> Bool {
        routine.deletedAt == nil && routine.archivedAt == nil
    }
}
