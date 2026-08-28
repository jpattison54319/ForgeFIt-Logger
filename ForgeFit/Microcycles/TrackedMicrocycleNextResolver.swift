import ForgeCore
import ForgeData
import Foundation

enum TrackedMicrocycleNextResolution: Equatable {
    case routine(id: UUID, title: String)
    case chooseWorkout(message: String)
}

extension RoutineModel {
    var isAvailableForWorkoutStart: Bool {
        guard deletedAt == nil, archivedAt == nil else { return false }
        return !exercises.isEmpty || hasStructurallyValidWorkoutBlock
    }

    func isAvailableForWorkoutStart(exercises library: [ExerciseLibraryModel]) -> Bool {
        guard deletedAt == nil, archivedAt == nil else { return false }
        let availableExerciseIDs = Set(
            library.lazy.filter { $0.deletedAt == nil }.map(\.id)
        )
        let hasAvailableExercise = exercises.contains {
            availableExerciseIDs.contains($0.exerciseID)
        }
        let hasAvailableBlock = blocks.contains { block in
            switch block.kind {
            case .conditioning:
                guard let plan = ConditioningPlan.decode(from: block.planJSON),
                      !plan.isEmpty else { return false }
                return plan.sections
                    .flatMap(\.movements)
                    .allSatisfy { availableExerciseIDs.contains($0.exerciseID) }
            case .yoga:
                return YogaFlowPlan.decode(from: block.planJSON)?.hasSteps == true
            }
        }
        let hasAvailableLegacyConditioning: Bool = {
            guard let plan = ConditioningPlan.decode(from: conditioningPlanJSON),
                  !plan.isEmpty else { return false }
            return plan.sections
                .flatMap(\.movements)
                .allSatisfy { availableExerciseIDs.contains($0.exerciseID) }
        }()
        return hasAvailableExercise || hasAvailableBlock || hasAvailableLegacyConditioning
    }

    private var hasStructurallyValidWorkoutBlock: Bool {
        let hasValidFirstClassBlock = blocks.contains { block in
            switch block.kind {
            case .conditioning:
                return ConditioningPlan.decode(from: block.planJSON)?.isEmpty == false
            case .yoga:
                return YogaFlowPlan.decode(from: block.planJSON)?.hasSteps == true
            }
        }
        let hasValidLegacyConditioning =
            ConditioningPlan.decode(from: conditioningPlanJSON)?.isEmpty == false
        return hasValidFirstClassBlock || hasValidLegacyConditioning
    }
}

/// One deterministic policy for every "next workout" surface. It follows the
/// active tracked microcycle's frozen window, resolves alternating slots from
/// completed history, and repeats a completed cycle in continuous slot order.
@MainActor
enum TrackedMicrocycleNextResolver {
    static func resolve(
        trackings: [MicrocycleTrackingModel],
        windows: [MicrocycleWindowModel],
        routines: [RoutineModel],
        alternations: [RoutineAlternationModel],
        workouts: [WorkoutModel],
        now: Date = .now
    ) -> TrackedMicrocycleNextResolution {
        let routines = RoutineDeduplicator.canonicalRoutines(routines)
        guard let tracking = MicrocycleTrackingService.activeTracking(trackings) else {
            return .chooseWorkout(message: "Choose a workout because no microcycle is being tracked.")
        }
        guard tracking.isActive else {
            return .chooseWorkout(message: "Your tracked microcycle needs attention before ForgeFit can choose the next workout.")
        }
        guard let window = MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: windows,
            now: now
        ) else {
            return .chooseWorkout(message: "Choose a workout because the current microcycle window is unavailable.")
        }

        let progress = MicrocycleTrackingService.progress(
            for: window,
            windows: windows,
            workouts: workouts
        )
        let orderedSlots = progress.routines.sorted {
            if $0.routine.position != $1.routine.position {
                return $0.routine.position < $1.routine.position
            }
            return $0.routine.id.uuidString < $1.routine.id.uuidString
        }
        guard !orderedSlots.isEmpty else {
            return .chooseWorkout(message: "Choose a workout because this microcycle has no available routines.")
        }

        let slot: MicrocycleRoutineSnapshot
        if let firstIncomplete = orderedSlots.first(where: { !$0.isCompleted }) {
            slot = firstIncomplete.routine
        } else {
            let memberIDs = Set(orderedSlots.flatMap { $0.routine.memberIDs })
            let effectiveDates = effectiveWorkoutDates(
                trackingID: tracking.id,
                windows: windows,
                workouts: workouts
            )
            let latestRoutineID = workouts
                .filter {
                    $0.deletedAt == nil
                        && $0.endedAt != nil
                        && $0.routineID.map(memberIDs.contains) == true
                        && effectiveDates[$0.id].map {
                            window.startsAt <= $0 && $0 < window.endsAt
                        } == true
                }
                .max {
                    let lhsEnd = $0.endedAt ?? .distantPast
                    let rhsEnd = $1.endedAt ?? .distantPast
                    if lhsEnd != rhsEnd { return lhsEnd < rhsEnd }
                    return $0.id.uuidString < $1.id.uuidString
                }?
                .routineID

            let latestIndex = latestRoutineID.flatMap { routineID in
                orderedSlots.firstIndex { $0.routine.memberIDs.contains(routineID) }
            } ?? (orderedSlots.count - 1)
            slot = orderedSlots[(latestIndex + 1) % orderedSlots.count].routine
        }

        let targetID: UUID
        if slot.isAlternating {
            guard let state = RoutineAlternationService.state(
                containing: slot.id,
                alternations: alternations,
                routines: routines,
                workouts: workouts
            ), slot.memberIDs.contains(state.due.id) else {
                return .chooseWorkout(message: "Choose a workout because an alternating routine in this microcycle needs attention.")
            }
            targetID = state.due.id
        } else {
            targetID = slot.id
        }

        guard let routine = routines.first(where: {
            $0.id == targetID && $0.isAvailableForWorkoutStart
        }) else {
            return .chooseWorkout(message: "Choose a workout because the next routine is no longer available.")
        }
        return .routine(id: routine.id, title: routine.name)
    }

    /// A backfilled workout belongs to its assigned day for this tracking run;
    /// all other workouts keep their real start date. Newest assignment wins,
    /// matching `MicrocycleTrackingService.progress`.
    private static func effectiveWorkoutDates(
        trackingID: UUID,
        windows: [MicrocycleWindowModel],
        workouts: [WorkoutModel]
    ) -> [UUID: Date] {
        var assignments: [UUID: MicrocycleDayAssignment] = [:]
        let allAssignments = windows
            .filter { $0.trackingID == trackingID && $0.deletedAt == nil }
            .flatMap(\.dayAssignments)
        for assignment in allAssignments {
            if let existing = assignments[assignment.workoutID],
               existing.assignedAt > assignment.assignedAt
                || (existing.assignedAt == assignment.assignedAt
                    && existing.id.uuidString > assignment.id.uuidString) {
                continue
            }
            assignments[assignment.workoutID] = assignment
        }
        return Dictionary(uniqueKeysWithValues: workouts.map {
            ($0.id, assignments[$0.id]?.day ?? $0.startedAt)
        })
    }
}
