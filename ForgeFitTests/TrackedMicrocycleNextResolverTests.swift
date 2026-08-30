import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct TrackedMicrocycleNextResolverTests {
    private let userID = ForgeFitDemo.userID
    private let start = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func noActiveTrackingRequiresAnExplicitChoice() {
        let resolution = TrackedMicrocycleNextResolver.resolve(
            trackings: [],
            windows: [],
            routines: [],
            alternations: [],
            workouts: [],
            now: start
        )

        #expect(resolution == .chooseWorkout(
            message: "Choose a workout because no microcycle is being tracked."
        ))
    }

    @Test func firstIncompleteSlotWinsInFrozenOrder() {
        let first = routine("Upper", position: 0)
        let second = routine("Lower", position: 1)
        let tracking = activeTracking()
        let window = currentWindow(
            tracking: tracking,
            snapshots: [snapshot(first), snapshot(second)]
        )
        let completedFirst = completedWorkout(
            routine: first,
            startedAt: start.addingTimeInterval(100)
        )

        let resolution = TrackedMicrocycleNextResolver.resolve(
            trackings: [tracking],
            windows: [window],
            routines: [second, first],
            alternations: [],
            workouts: [completedFirst],
            now: start.addingTimeInterval(200)
        )

        #expect(resolution == .routine(id: second.id, title: "Lower"))
    }

    @Test func duplicateRoutineIDResolvesToTheFreshestAuthoredGraph() {
        let id = UUID()
        let staleExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            updatedAt: start.addingTimeInterval(100)
        )
        let movedStaleGraph = RoutineModel(
            id: id,
            userID: userID,
            name: "Stale",
            position: 3,
            updatedAt: start.addingTimeInterval(900),
            exercises: [staleExercise]
        )
        let editedExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: UUID(),
            updatedAt: start.addingTimeInterval(500)
        )
        let editedGraph = RoutineModel(
            id: id,
            userID: userID,
            name: "Edited",
            position: 0,
            updatedAt: start.addingTimeInterval(500),
            exercises: [editedExercise]
        )
        let tracking = activeTracking()
        let window = currentWindow(
            tracking: tracking,
            snapshots: [snapshot(editedGraph)]
        )

        let resolution = TrackedMicrocycleNextResolver.resolve(
            trackings: [tracking],
            windows: [window],
            routines: [movedStaleGraph, editedGraph],
            alternations: [],
            workouts: [],
            now: start.addingTimeInterval(200)
        )

        #expect(resolution == .routine(id: id, title: "Edited"))
    }

    @Test func incompleteAlternatingSlotUsesTheCurrentlyDueGroupMember() {
        let owner = routine("A", position: 0)
        let partner = routine("B", position: 1)
        let third = routine("C", position: 2)
        let tracking = activeTracking()
        let window = currentWindow(
            tracking: tracking,
            snapshots: [MicrocycleRoutineSnapshot(
                id: owner.id,
                name: owner.name,
                position: 0,
                alternateRoutineID: partner.id,
                alternateRoutineName: partner.name,
                memberRoutineIDs: [owner.id, partner.id, third.id],
                memberRoutineNames: [owner.name, partner.name, third.name]
            )]
        )
        let alternation = RoutineAlternationModel(
            userID: userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id,
            memberRoutineIDs: [owner.id, partner.id, third.id],
            createdAt: start.addingTimeInterval(-1_000)
        )
        let previousPartnerWorkout = completedWorkout(
            routine: partner,
            startedAt: start.addingTimeInterval(-500)
        )

        let resolution = TrackedMicrocycleNextResolver.resolve(
            trackings: [tracking],
            windows: [window],
            routines: [owner, partner, third],
            alternations: [alternation],
            workouts: [previousPartnerWorkout],
            now: start.addingTimeInterval(200)
        )

        #expect(resolution == .routine(id: third.id, title: "C"))
    }

    @Test func completedWindowRepeatsContinuouslyAndWraps() {
        let first = routine("A", position: 0)
        let second = routine("B", position: 1)
        let third = routine("C", position: 2)
        let tracking = activeTracking()
        let window = currentWindow(
            tracking: tracking,
            snapshots: [snapshot(first), snapshot(second), snapshot(third)]
        )
        let workouts = [
            completedWorkout(routine: first, startedAt: start.addingTimeInterval(100)),
            completedWorkout(routine: second, startedAt: start.addingTimeInterval(200)),
            completedWorkout(routine: third, startedAt: start.addingTimeInterval(300)),
        ]

        let resolution = TrackedMicrocycleNextResolver.resolve(
            trackings: [tracking],
            windows: [window],
            routines: [first, second, third],
            alternations: [],
            workouts: workouts,
            now: start.addingTimeInterval(400)
        )

        #expect(resolution == .routine(id: first.id, title: "A"))
    }

    @Test func needsAttentionNeverGuesses() {
        let tracking = activeTracking(state: "needsAttention")
        let resolution = TrackedMicrocycleNextResolver.resolve(
            trackings: [tracking],
            windows: [],
            routines: [],
            alternations: [],
            workouts: [],
            now: start
        )

        #expect(resolution == .chooseWorkout(
            message: "Your tracked microcycle needs attention before ForgeFit can choose the next workout."
        ))
    }

    @Test func startAvailabilityRequiresLiveContent() {
        let exercise = ExerciseLibraryModel(name: "Bench Press")
        let routine = RoutineModel(
            userID: userID,
            name: "Push",
            exercises: [RoutineExerciseModel(
                userID: userID,
                exerciseID: exercise.id
            )]
        )

        #expect(routine.isAvailableForWorkoutStart(exercises: [exercise]))
        exercise.deletedAt = start
        #expect(!routine.isAvailableForWorkoutStart(exercises: [exercise]))

        let emptyConditioning = RoutineModel(
            userID: userID,
            name: "Empty Conditioning",
            conditioningPlanJSON: ConditioningPlan(sections: []).encodedJSON()
        )
        #expect(!emptyConditioning.isAvailableForWorkoutStart)
        #expect(!emptyConditioning.isAvailableForWorkoutStart(exercises: []))
    }

    private func routine(_ name: String, position: Int) -> RoutineModel {
        RoutineModel(
            userID: userID,
            name: name,
            position: position,
            exercises: [
                RoutineExerciseModel(
                    userID: userID,
                    exerciseID: UUID(),
                    position: 0
                )
            ]
        )
    }

    private func snapshot(_ routine: RoutineModel) -> MicrocycleRoutineSnapshot {
        MicrocycleRoutineSnapshot(
            id: routine.id,
            name: routine.name,
            position: routine.position
        )
    }

    private func activeTracking(state: String = "active") -> MicrocycleTrackingModel {
        MicrocycleTrackingModel(
            userID: userID,
            folderID: UUID(),
            folderName: "Tracked",
            anchorDate: start,
            durationDays: 7,
            timeZoneIdentifier: "UTC",
            stateRaw: state,
            createdAt: start,
            updatedAt: start
        )
    }

    private func currentWindow(
        tracking: MicrocycleTrackingModel,
        snapshots: [MicrocycleRoutineSnapshot]
    ) -> MicrocycleWindowModel {
        MicrocycleWindowModel(
            userID: userID,
            trackingID: tracking.id,
            folderID: tracking.folderID,
            folderName: tracking.folderName,
            index: 0,
            startsAt: start,
            endsAt: start.addingTimeInterval(7 * 24 * 60 * 60),
            timeZoneIdentifier: "UTC",
            routines: snapshots,
            createdAt: start,
            updatedAt: start
        )
    }

    private func completedWorkout(
        routine: RoutineModel,
        startedAt: Date
    ) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            routineID: routine.id,
            title: routine.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
    }
}
