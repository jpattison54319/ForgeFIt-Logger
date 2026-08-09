import ForgeData
import Foundation

/// Applies one completed drag snapshot to the plan models. Every affected
/// destination is normalized to contiguous positions in the same mutation.
enum RoutineReorderPersistence {
    @discardableResult
    static func apply(
        _ session: RoutineReorderSession,
        to routines: [RoutineModel],
        now: Date = .now
    ) -> Bool {
        var routinesByID: [UUID: RoutineModel] = [:]
        for routine in routines where routinesByID[routine.id] == nil {
            routinesByID[routine.id] = routine
        }

        var changed = false
        for destination in session.changedDestinations {
            let orderedRoutines = session.routineIDs(in: destination).compactMap { routinesByID[$0] }
            for (index, routine) in orderedRoutines.enumerated() {
                if routine.folderID != destination.folderID || routine.position != index {
                    routine.folderID = destination.folderID
                    routine.position = index
                    routine.updatedAt = now
                    changed = true
                }
            }
        }
        return changed
    }
}
