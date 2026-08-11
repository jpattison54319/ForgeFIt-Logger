import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-004 regression suite: onboarding dismissal cleanup (`clearStarterSlate`
/// → `StarterSlateCleanup`) must delete seeded starter content only — the
/// starter routine, its setup note, and unfinished workouts derived from the
/// starter routine — while every genuine user-created unfinished workout
/// survives. Uses the existing `WorkoutModel.routineID` provenance stamp; no
/// schema field was added.
@MainActor
struct StarterSlateCleanupTests {
    private let starterRoutineID = ForgeFitDemo.starterRoutineID
    private let userID = UUID()

    @Test func seededStarterWorkoutPredicateUsesRoutineProvenanceOnly() {
        let starterDerived = WorkoutModel(userID: userID, routineID: starterRoutineID, startedAt: .now)
        #expect(StarterSlatePolicy.isSeededStarterWorkout(starterDerived))

        // Ad-hoc, cardio/yoga quick starts carry routineID == nil.
        let adHoc = WorkoutModel(userID: userID, title: "Workout")
        #expect(!StarterSlatePolicy.isSeededStarterWorkout(adHoc))

        // Any other routine is real user work.
        let otherRoutine = WorkoutModel(userID: userID, routineID: UUID(), title: "Leg day")
        #expect(!StarterSlatePolicy.isSeededStarterWorkout(otherRoutine))

        // Completed sessions are history and were never slate-cleaned.
        let completed = WorkoutModel(
            userID: userID,
            routineID: starterRoutineID,
            startedAt: .now.addingTimeInterval(-3_600),
            endedAt: .now
        )
        #expect(!StarterSlatePolicy.isSeededStarterWorkout(completed))
    }

    /// The acceptance-criterion flow: a store holding seeded starter content
    /// AND a user-created in-progress workout (the deep-link/workout case from
    /// the audit) has the slate cleaned without touching the user's workout.
    @Test func cleanupRemovesSeededStarterContentAndPreservesUserWorkInProgress() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        // Seeded starter data: the routine, its setup note, and an unfinished
        // workout derived from the starter routine.
        context.insert(RoutineModel(
            id: starterRoutineID,
            userID: ForgeFitDemo.userID,
            name: "Full Body A",
            notes: "Starter routine",
            position: 0
        ))
        context.insert(UserExerciseNoteModel(
            id: ForgeFitDemo.machinePressNoteID,
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            note: "Keep shoulder blades pinned before the first rep."
        ))
        let starterDerived = WorkoutModel(userID: userID, routineID: starterRoutineID, startedAt: .now)
        context.insert(starterDerived)

        // Real user work that must survive: an in-progress workout (started by
        // a replaying deep link), an in-progress workout from the user's own
        // routine, and a completed session.
        let deepLinkWorkout = WorkoutModel(userID: userID, title: "Workout", sourceDevice: "iphone")
        context.insert(deepLinkWorkout)
        let userRoutineWorkout = WorkoutModel(userID: userID, routineID: UUID(), title: "Leg day")
        context.insert(userRoutineWorkout)
        let completed = WorkoutModel(
            userID: userID,
            routineID: starterRoutineID,
            startedAt: .now.addingTimeInterval(-3_600),
            endedAt: .now
        )
        context.insert(completed)
        try context.save()

        try StarterSlateCleanup.run(in: context)

        let remainingWorkoutIDs = Set(try context.fetch(FetchDescriptor<WorkoutModel>()).map(\.id))
        #expect(remainingWorkoutIDs == Set([deepLinkWorkout.id, userRoutineWorkout.id, completed.id]))
        #expect(try context.fetchCount(FetchDescriptor<RoutineModel>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<UserExerciseNoteModel>()) == 0)
    }

    /// User-authored notes ride the same demo `userID` as the seeded setup
    /// note, so the cleanup must key on the fixed seeded note ID — never on
    /// the shared user ID.
    @Test func cleanupRemovesOnlyTheSeededSetupNoteAndKeepsUserNotes() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        context.insert(UserExerciseNoteModel(
            id: ForgeFitDemo.machinePressNoteID,
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            note: "Keep shoulder blades pinned before the first rep."
        ))
        let userNote = UserExerciseNoteModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            note: "Wrists feel better with a neutral grip."
        )
        context.insert(userNote)
        try context.save()

        try StarterSlateCleanup.run(in: context)

        let remaining = try context.fetch(FetchDescriptor<UserExerciseNoteModel>())
        #expect(remaining.map(\.id) == [userNote.id])
    }

    /// The global runtime (rest timers, GPS/cardio recording, watch state, HR,
    /// Live Activity) must only be torn down when the currently active workout
    /// is the seeded starter workout being deleted — a preserved genuine
    /// workout keeps its runtime.
    @Test func runtimeCancellationTargetsOnlyTheActiveStarterDerivedWorkout() {
        let starterDerived = WorkoutModel(userID: userID, routineID: starterRoutineID, startedAt: .now)
        #expect(StarterSlatePolicy.cancelsLiveRuntimeForDeletion(activeWorkout: starterDerived))

        let adHoc = WorkoutModel(userID: userID, title: "Workout")
        #expect(!StarterSlatePolicy.cancelsLiveRuntimeForDeletion(activeWorkout: adHoc))
        let otherRoutine = WorkoutModel(userID: userID, routineID: UUID(), title: "Leg day")
        #expect(!StarterSlatePolicy.cancelsLiveRuntimeForDeletion(activeWorkout: otherRoutine))
        let completed = WorkoutModel(
            userID: userID,
            routineID: starterRoutineID,
            startedAt: .now.addingTimeInterval(-3_600),
            endedAt: .now
        )
        #expect(!StarterSlatePolicy.cancelsLiveRuntimeForDeletion(activeWorkout: completed))
        #expect(!StarterSlatePolicy.cancelsLiveRuntimeForDeletion(activeWorkout: nil))
    }

    @Test func cleanupWithOnlyUserWorkDeletesNothing() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        let adHoc = WorkoutModel(userID: userID, title: "Workout")
        context.insert(adHoc)
        let otherRoutine = WorkoutModel(userID: userID, routineID: UUID(), title: "Push day")
        context.insert(otherRoutine)
        try context.save()

        try StarterSlateCleanup.run(in: context)

        let remaining = try context.fetch(FetchDescriptor<WorkoutModel>())
        #expect(Set(remaining.map(\.id)) == Set([adHoc.id, otherRoutine.id]))
    }
}
