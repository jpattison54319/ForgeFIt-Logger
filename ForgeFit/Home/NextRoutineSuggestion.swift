import ForgeData
import Foundation

/// Picks what to suggest training next, drilling through whichever training
/// cycle is active: a microcycle (most specific — exactly what you're
/// running) beats a mesocycle (rotates across every microcycle nested
/// inside it), which beats best-guessing from every routine by what was
/// done last.
///
/// A mesocycle and one of its microcycles are independent slots and can be
/// active at the same time. If the active microcycle has nothing suggestible
/// (for example, no routines with exercises), this falls through to the
/// active mesocycle before falling
/// through to the global list — an active-but-empty slot never produces an
/// empty suggestion when a broader one would work.
@MainActor
enum NextRoutineSuggestion {
    struct Result: Equatable {
        let routineID: UUID
        let reason: String
        let alternatingWith: String?
    }

    private struct Slot {
        let routine: RoutineModel
        let memberIDs: Set<UUID>
        let alternatingWith: String?
    }

    static func suggest(
        routines: [RoutineModel],
        completedWorkouts: [WorkoutModel],
        alternations: [RoutineAlternationModel] = [],
        activeMicrocycleFolderID: UUID?,
        activeMesocycleFolderID: UUID?,
        mesocycleSubtree: (UUID) -> Set<UUID>,
        now: Date = Date()
    ) -> Result? {
        let active = routines
            .filter { $0.deletedAt == nil && $0.archivedAt == nil && !$0.exercises.isEmpty }
            .sorted { $0.position < $1.position }
        guard !active.isEmpty else { return nil }

        let scoped: (pool: [RoutineModel], label: String)? = {
            if let microcycleID = activeMicrocycleFolderID {
                let pool = active.filter { $0.folderID == microcycleID }
                if !pool.isEmpty { return (pool, "microcycle") }
            }
            if let mesocycleID = activeMesocycleFolderID {
                let subtree = mesocycleSubtree(mesocycleID)
                let pool = active.filter { r in r.folderID.map(subtree.contains) ?? false }
                if !pool.isEmpty { return (pool, "mesocycle") }
            }
            return nil
        }()
        let pool = scoped?.pool ?? active
        let slots = slots(
            from: pool,
            allRoutines: active,
            alternations: alternations,
            workouts: completedWorkouts
        )
        guard !slots.isEmpty else { return nil }

        let completed = completedWorkouts
            .filter { $0.endedAt != nil && $0.deletedAt == nil }
            .sorted {
                let lhsEnd = $0.endedAt ?? .distantPast
                let rhsEnd = $1.endedAt ?? .distantPast
                if lhsEnd != rhsEnd { return lhsEnd > rhsEnd }
                return $0.id.uuidString > $1.id.uuidString
            }

        if let lastDone = completed.first(where: { workout in
            slots.contains { slot in workout.routineID.map(slot.memberIDs.contains) == true }
        }), let lastIndex = slots.firstIndex(where: { slot in
            lastDone.routineID.map(slot.memberIDs.contains) == true
        }) {
            let next = slots[(lastIndex + 1) % slots.count]
            let lastName = active.first(where: { $0.id == lastDone.routineID })?.name ?? slots[lastIndex].routine.name
            var reason = scoped.map { "Next in your \($0.label)" } ?? "Up after \(lastName)"
            if let lastTime = completed.first(where: { workout in
                workout.routineID.map(next.memberIDs.contains) == true
            })?.startedAt {
                reason += " · last done \(lastTime.formatted(.relative(presentation: .named)))"
            }
            return Result(
                routineID: next.routine.id,
                reason: reason,
                alternatingWith: next.alternatingWith
            )
        }
        return Result(
            routineID: slots[0].routine.id,
            reason: scoped.map { "Start your \($0.label)" } ?? "Start your plan",
            alternatingWith: slots[0].alternatingWith
        )
    }

    /// The owner contributes one ordered slot. Its partner is suppressed only
    /// when the owner is also in this scope; a partner whose owner lives in a
    /// different microcycle remains an ordinary requirement there.
    private static func slots(
        from pool: [RoutineModel],
        allRoutines: [RoutineModel],
        alternations: [RoutineAlternationModel],
        workouts: [WorkoutModel]
    ) -> [Slot] {
        let poolIDs = Set(pool.map(\.id))
        let states = RoutineAlternationService.states(
            alternations: alternations,
            routines: allRoutines,
            workouts: workouts
        )
        let stateByOwnerID = Dictionary(states.map { ($0.owner.id, $0) }, uniquingKeysWith: { first, _ in first })
        let suppressedPartnerIDs = Set(states.compactMap { state in
            poolIDs.contains(state.owner.id) && poolIDs.contains(state.partner.id)
                ? state.partner.id
                : nil
        })

        return pool.compactMap { routine in
            guard !suppressedPartnerIDs.contains(routine.id) else { return nil }
            guard let state = stateByOwnerID[routine.id] else {
                return Slot(routine: routine, memberIDs: [routine.id], alternatingWith: nil)
            }
            return Slot(
                routine: state.due,
                memberIDs: [state.owner.id, state.partner.id],
                alternatingWith: state.other.name
            )
        }
    }
}
