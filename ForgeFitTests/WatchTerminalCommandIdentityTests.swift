import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// FF-002 — terminal Watch commands are bound to their target workout.
///
/// The phone handler delivers a finish/discard only for the exact workout the
/// carried `workoutID` names (matching identity reproduces the pre-binding
/// behavior). A stale command for a superseded workout — or an identity-less
/// legacy command — is dropped, so a delayed WatchConnectivity delivery can
/// never terminate a newer workout.
@MainActor
struct WatchTerminalCommandIdentityTests {
    private let userID = ForgeFitDemo.userID

    private func insertWorkout(
        id: UUID,
        title: String,
        startedAt: Date,
        in context: ModelContext
    ) -> WorkoutModel {
        let workout = WorkoutModel(
            id: id,
            userID: userID,
            title: title,
            startedAt: startedAt,
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: UUID(),
                sets: [SetModel(
                    userID: userID,
                    position: 0,
                    reps: 5,
                    weight: 100,
                    completedAt: .now
                )]
            )]
        )
        context.insert(workout)
        return workout
    }

    private func makeLink(context: ModelContext) -> WatchLink {
        let link = WatchLink()
        link.configure(context: context)
        return link
    }

    @Test func matchingFinishEndsTheWorkoutItNames() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = insertWorkout(id: UUID(), title: "Watch Finish", startedAt: .now, in: context)
        try context.save()

        makeLink(context: context).handle(
            .finishWorkout(workoutID: workout.id, metrics: nil, savedToHealth: true)
        )

        #expect(workout.endedAt != nil)
        #expect(workout.deletedAt == nil)
    }

    @Test func matchingDiscardTombstonesTheWorkoutItNames() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = insertWorkout(id: UUID(), title: "Watch Discard", startedAt: .now, in: context)
        try context.save()

        makeLink(context: context).handle(
            .discardWorkout(workoutID: workout.id)
        )

        #expect(workout.deletedAt != nil)
        #expect(workout.endedAt == nil)
    }

    /// A queued finish for a workout the phone already ended arrives while a
    /// newer workout is active — the confirmed FF-002 trigger. The newer
    /// workout must survive untouched.
    @Test func staleFinishForASupersededWorkoutLeavesTheNewerWorkoutUntouched() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let oldWorkout = insertWorkout(
            id: UUID(),
            title: "A",
            startedAt: .now.addingTimeInterval(-600),
            in: context
        )
        oldWorkout.endedAt = .now.addingTimeInterval(-300) // A finished on the phone
        let newWorkout = insertWorkout(id: UUID(), title: "B", startedAt: .now, in: context)
        try context.save()

        makeLink(context: context).handle(
            .finishWorkout(workoutID: oldWorkout.id, metrics: nil, savedToHealth: true)
        )

        #expect(newWorkout.endedAt == nil)
        #expect(newWorkout.deletedAt == nil)
    }

    /// The discard twin of the stale-finish scenario: A's queued discard must
    /// be ignored once B is active.
    @Test func staleDiscardForASupersededWorkoutLeavesTheNewerWorkoutUntouched() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let oldWorkout = insertWorkout(
            id: UUID(),
            title: "A",
            startedAt: .now.addingTimeInterval(-600),
            in: context
        )
        oldWorkout.endedAt = .now.addingTimeInterval(-300)
        let newWorkout = insertWorkout(id: UUID(), title: "B", startedAt: .now, in: context)
        try context.save()

        makeLink(context: context).handle(
            .discardWorkout(workoutID: oldWorkout.id)
        )

        #expect(newWorkout.deletedAt == nil)
        #expect(newWorkout.endedAt == nil)
    }

    /// Legacy wire form (no `workoutID` key from a pre-binding Watch build):
    /// unverifiable, so it is refused rather than applied to the active
    /// workout.
    @Test func finishWithoutIdentityIsRefused() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = insertWorkout(id: UUID(), title: "Legacy", startedAt: .now, in: context)
        try context.save()

        makeLink(context: context).handle(
            .finishWorkout(workoutID: nil, metrics: nil, savedToHealth: true)
        )

        #expect(workout.endedAt == nil)
        #expect(workout.deletedAt == nil)
    }

    @Test func discardWithoutIdentityIsRefused() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = insertWorkout(id: UUID(), title: "Legacy", startedAt: .now, in: context)
        try context.save()

        makeLink(context: context).handle(
            .discardWorkout(workoutID: nil)
        )

        #expect(workout.deletedAt == nil)
        #expect(workout.endedAt == nil)
    }

    /// A terminal command that names a workout the phone no longer has active
    /// is refused — nothing is created, ended, or deleted. (The reject branch
    /// also re-publishes the phone's authoritative snapshot; that delivery is
    /// not observable in unit tests — WCSession context sends bail when no
    /// watch app is installed — so it is covered by the `WatchTerminalCommand
    /// Policy` tests and the simulator/hardware validation instead, without
    /// invasive test hooks.)
    @Test func terminalCommandsWithNoActiveWorkoutAreRefused() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let link = makeLink(context: context)

        link.handle(.finishWorkout(workoutID: UUID(), metrics: nil, savedToHealth: true))
        link.handle(.discardWorkout(workoutID: UUID()))

        #expect(try context.fetch(FetchDescriptor<WorkoutModel>()).isEmpty)
    }
}