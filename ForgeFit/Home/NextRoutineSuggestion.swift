import ForgeData
import Foundation

/// Picks what to suggest training next, drilling through whichever training
/// cycle is active: a mesocycle (most specific — exactly what you're
/// running) beats a macrocycle (rotates across every mesocycle nested
/// inside it), which beats best-guessing from every routine by what was
/// done last.
///
/// A macrocycle and one of its mesocycles are independent slots and can be
/// active at the same time — a macro can hold several mesocycles, so
/// "active macro" and "active meso" answer different questions ("what
/// season am I in" vs "what exact block am I running"). If the active
/// mesocycle turns out to have nothing suggestible (e.g. no routines with
/// exercises), this falls through to the active macrocycle before falling
/// through to the global list — an active-but-empty slot never produces an
/// empty suggestion when a broader one would work.
enum NextRoutineSuggestion {
    struct Result: Equatable {
        let routineID: UUID
        let reason: String
    }

    static func suggest(
        routines: [RoutineModel],
        completedWorkouts: [WorkoutModel],
        activeMesoFolderID: UUID?,
        activeMacroFolderID: UUID?,
        macroSubtree: (UUID) -> Set<UUID>,
        now: Date = Date()
    ) -> Result? {
        let active = routines
            .filter { $0.deletedAt == nil && $0.archivedAt == nil && !$0.exercises.isEmpty }
            .sorted { $0.position < $1.position }
        guard !active.isEmpty else { return nil }

        let scoped: (pool: [RoutineModel], label: String)? = {
            if let mesoID = activeMesoFolderID {
                let pool = active.filter { $0.folderID == mesoID }
                if !pool.isEmpty { return (pool, "mesocycle") }
            }
            if let macroID = activeMacroFolderID {
                let subtree = macroSubtree(macroID)
                let pool = active.filter { r in r.folderID.map(subtree.contains) ?? false }
                if !pool.isEmpty { return (pool, "macrocycle") }
            }
            return nil
        }()
        let pool = scoped?.pool ?? active

        let completed = completedWorkouts
            .filter { $0.endedAt != nil && $0.deletedAt == nil }
            .sorted { $0.startedAt > $1.startedAt }

        if let lastDone = completed.first(where: { w in pool.contains { $0.id == w.routineID } }),
           let lastIndex = pool.firstIndex(where: { $0.id == lastDone.routineID }) {
            let next = pool[(lastIndex + 1) % pool.count]
            var reason = scoped.map { "Next in your \($0.label)" } ?? "Up after \(pool[lastIndex].name)"
            if let lastTime = completed.first(where: { $0.routineID == next.id })?.startedAt {
                reason += " · last done \(lastTime.formatted(.relative(presentation: .named)))"
            }
            return Result(routineID: next.id, reason: reason)
        }
        return Result(routineID: pool[0].id, reason: scoped.map { "Start your \($0.label)" } ?? "Start your plan")
    }
}
