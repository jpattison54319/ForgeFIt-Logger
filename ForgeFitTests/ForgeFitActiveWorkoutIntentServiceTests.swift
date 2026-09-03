import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ForgeFitActiveWorkoutIntentServiceTests {
    private let userID = UUID(uuidString: "00000000-0000-7000-8000-00000000D101")!
    private let now = Date(timeIntervalSince1970: 1_700_100_000)

    @Test func activeSetsFollowSupersetRoundsAndKeepDropsWithTheirParent() throws {
        let (container, context) = try TestStore.make()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let exerciseA = UUID(uuidString: "00000000-0000-7000-8000-00000000D111")!
        let exerciseB = UUID(uuidString: "00000000-0000-7000-8000-00000000D112")!
        let a1 = SetModel(userID: userID, position: 0, setType: .working)
        let aDrop = SetModel(userID: userID, position: 1, setType: .drop)
        let a2 = SetModel(userID: userID, position: 2, setType: .working)
        let b1 = SetModel(userID: userID, position: 0, setType: .working)
        let b2 = SetModel(userID: userID, position: 1, setType: .working)
        let workout = WorkoutModel(
            userID: userID,
            title: "Superset",
            startedAt: now.addingTimeInterval(-600),
            sourceDevice: "iphone",
            exercises: [
                WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: exerciseA,
                    position: 0,
                    supersetGroup: 1,
                    restSeconds: 0,
                    sets: [a1, aDrop, a2]
                ),
                WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: exerciseB,
                    position: 1,
                    supersetGroup: 1,
                    restSeconds: 0,
                    sets: [b1, b2]
                ),
            ]
        )
        context.insert(ExerciseLibraryModel(id: exerciseA, name: "Bench Press"))
        context.insert(ExerciseLibraryModel(id: exerciseB, name: "Cable Row"))
        context.insert(workout)
        try context.save()

        let service = makeService(container: container, defaults: defaults)

        #expect(service.activeSetSnapshots().map(\.setID) == [a1.id, aDrop.id, b1.id, a2.id, b2.id])
        #expect(service.activeSetSnapshots().map(\.spokenName) == [
            "Bench Press set 1",
            "Bench Press drop set 1",
            "Cable Row set 1",
            "Bench Press set 2",
            "Cable Row set 2",
        ])
    }

    @Test func completingAnIdentityBoundSetPersistsPerformedValuesOnlyOnThatSet() throws {
        let fixture = try makeOrdinaryWorkout()
        defer { fixture.cleanupDefaults() }
        fixture.defaults.set(true, forKey: WorkoutEffortPolicy.loggingEnabledKey)
        fixture.defaults.set(false, forKey: WorkoutEffortPolicy.failureTrainingKey)
        let service = makeService(container: fixture.container, defaults: fixture.defaults)
        let expected = try #require(service.nextPendingSet())

        let committed = try service.completeSet(
            expected: expected,
            values: ForgeFitSetCommandValues(
                reps: 8,
                loadKilograms: 102.5,
                rpe: 8.5,
                rir: nil,
                partialReps: nil
            )
        )

        #expect(committed.setID == fixture.firstSetID)
        #expect(committed.isCompleted)
        #expect(service.nextPendingSet()?.setID == fixture.secondSetID)

        let verification = ModelContext(fixture.container)
        let firstSetID = fixture.firstSetID
        let secondSetID = fixture.secondSetID
        let persistedFirst = try #require(verification.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == firstSetID }
        )).first)
        let persistedSecond = try #require(verification.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == secondSetID }
        )).first)
        #expect(persistedFirst.reps == 8)
        #expect(persistedFirst.modeWeight == 102.5)
        #expect(persistedFirst.rpe == 8.5)
        #expect(persistedFirst.rir == nil)
        #expect(persistedFirst.completedAt == now)
        #expect(persistedSecond.completedAt == nil)
        #expect(persistedSecond.reps == 6)
        #expect(persistedSecond.modeWeight == 110)
    }

    @Test func staleSetAnswerCannotOverwriteAConcurrentEditOrAdvanceAnotherSet() throws {
        let fixture = try makeOrdinaryWorkout()
        defer { fixture.cleanupDefaults() }
        fixture.defaults.set(true, forKey: WorkoutEffortPolicy.loggingEnabledKey)
        let service = makeService(container: fixture.container, defaults: fixture.defaults)
        let staleSnapshot = try #require(service.nextPendingSet())
        let firstSetID = fixture.firstSetID
        let edited = try #require(fixture.context.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == firstSetID }
        )).first)
        edited.reps = 12
        try fixture.context.save()

        do {
            _ = try service.completeSet(
                expected: staleSnapshot,
                values: ForgeFitSetCommandValues(
                    reps: 8,
                    loadKilograms: 100,
                    rpe: 8,
                    rir: nil,
                    partialReps: nil
                )
            )
            Issue.record("Expected a stale Siri answer to be rejected.")
        } catch let error as ForgeFitActiveWorkoutCommandError {
            #expect(error.message.contains("changed while Siri was asking"))
        }

        #expect(edited.reps == 12)
        #expect(edited.completedAt == nil)
        #expect(service.nextPendingSet()?.setID == fixture.firstSetID)
    }

    @Test func hiddenEffortCannotBeWrittenThroughTheSiriBoundary() throws {
        let fixture = try makeOrdinaryWorkout()
        defer { fixture.cleanupDefaults() }
        fixture.defaults.set(false, forKey: WorkoutEffortPolicy.loggingEnabledKey)
        let service = makeService(container: fixture.container, defaults: fixture.defaults)
        let expected = try #require(service.nextPendingSet())

        do {
            _ = try service.completeSet(
                expected: expected,
                values: ForgeFitSetCommandValues(
                    reps: 8,
                    loadKilograms: 100,
                    rpe: 9,
                    rir: nil,
                    partialReps: nil
                )
            )
            Issue.record("Expected hidden effort to be rejected.")
        } catch let error as ForgeFitActiveWorkoutCommandError {
            #expect(error.message.contains("effort logging is off"))
        }

        #expect(service.nextPendingSet()?.setID == fixture.firstSetID)
        #expect(service.nextPendingSet()?.isCompleted == false)
    }

    @Test func updateAndReopenStayBoundToTheOriginallyResolvedSet() throws {
        let fixture = try makeOrdinaryWorkout()
        defer { fixture.cleanupDefaults() }
        fixture.defaults.set(true, forKey: WorkoutEffortPolicy.loggingEnabledKey)
        let service = makeService(container: fixture.container, defaults: fixture.defaults)
        let original = try #require(service.nextPendingSet())

        let repsUpdated = try service.updateSet(
            expected: original,
            values: ForgeFitSetCommandValues(
                reps: 9,
                loadKilograms: nil,
                rpe: nil,
                rir: nil,
                partialReps: nil
            )
        )
        #expect(repsUpdated.setID == fixture.firstSetID)
        #expect(repsUpdated.reps == 9)
        #expect(!repsUpdated.isCompleted)

        let completed = try service.completeSet(
            expected: repsUpdated,
            values: ForgeFitSetCommandValues(
                reps: 9,
                loadKilograms: 100,
                rpe: 8,
                rir: nil,
                partialReps: nil
            )
        )
        let effortUpdated = try service.updateSet(
            expected: completed,
            values: ForgeFitSetCommandValues(
                reps: nil,
                loadKilograms: nil,
                rpe: nil,
                rir: 2,
                partialReps: nil
            )
        )
        #expect(effortUpdated.rpe == 8)
        #expect(effortUpdated.rir == 2)

        let reopened = try service.reopenSet(expected: effortUpdated)
        #expect(reopened.setID == fixture.firstSetID)
        #expect(!reopened.isCompleted)
        #expect(reopened.reps == 9)
        #expect(reopened.loadKilograms == 100)
        #expect(reopened.rpe == 8)
        #expect(reopened.rir == 2)
        #expect(service.nextPendingSet()?.setID == fixture.firstSetID)
    }

    @Test func structuredSetRequiresItsDedicatedRuntimeInsteadOfPartialVoiceMutation() throws {
        let (container, context) = try TestStore.make()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let exerciseID = UUID()
        let structured = SetModel(userID: userID, setType: .myoRep, reps: 12, weight: 40)
        let workout = WorkoutModel(
            userID: userID,
            title: "Structured",
            startedAt: now.addingTimeInterval(-300),
            sourceDevice: "iphone",
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: exerciseID,
                restSeconds: 0,
                sets: [structured]
            )]
        )
        context.insert(ExerciseLibraryModel(id: exerciseID, name: "Leg Extension"))
        context.insert(workout)
        try context.save()
        let service = makeService(container: container, defaults: defaults)
        let expected = try #require(service.nextPendingSet())

        #expect(expected.needsSpecializedUI)
        #expect(throws: ForgeFitActiveWorkoutCommandError.self) {
            try service.completeSet(
                expected: expected,
                values: ForgeFitSetCommandValues(
                    reps: 12,
                    loadKilograms: 40,
                    rpe: nil,
                    rir: nil,
                    partialReps: nil
                )
            )
        }
        #expect(structured.completedAt == nil)
    }

    @Test func finishSavesSessionExertionWithoutChangingTheReusableRoutine() throws {
        let (container, context) = try TestStore.make()
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let exerciseID = UUID()
        let routineSet = RoutineSetModel(userID: userID, targetRepsLow: 5, targetWeight: 50)
        let routineExercise = RoutineExerciseModel(
            userID: userID,
            exerciseID: exerciseID,
            sets: [routineSet]
        )
        let routine = RoutineModel(userID: userID, name: "Original Plan", exercises: [routineExercise])
        let completedSet = SetModel(
            userID: userID,
            reps: 8,
            weight: 100,
            sourceRoutineSetID: routineSet.id,
            completedAt: now.addingTimeInterval(-60)
        )
        let workout = WorkoutModel(
            userID: userID,
            routineID: routine.id,
            title: "Original Plan",
            startedAt: now.addingTimeInterval(-900),
            sourceDevice: "iphone",
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: exerciseID,
                sourceRoutineExerciseID: routineExercise.id,
                sets: [completedSet]
            )]
        )
        context.insert(ExerciseLibraryModel(id: exerciseID, name: "Back Squat"))
        context.insert(routine)
        context.insert(workout)
        try context.save()
        let service = makeService(
            container: container,
            defaults: defaults,
            finishEffects: noOpFinishEffects
        )
        let preview = try service.finishPreview()

        try service.finishWorkout(expected: preview, exertion: 7)

        let verification = ModelContext(container)
        let workoutID = workout.id
        let routineID = routine.id
        let persistedWorkout = try #require(verification.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.id == workoutID }
        )).first)
        let persistedRoutine = try #require(verification.fetch(FetchDescriptor<RoutineModel>(
            predicate: #Predicate { $0.id == routineID }
        )).first)
        #expect(persistedWorkout.endedAt == now)
        #expect(persistedWorkout.wholeSessionRPE == 7)
        #expect(persistedWorkout.wholeSessionRPERatedAt == now)
        #expect(persistedWorkout.wholeSessionRPEProtocolVersion == "whole-session-cr10-immediate-v1")
        #expect(persistedRoutine.exercises.first?.sets.first?.targetRepsLow == 5)
        #expect(persistedRoutine.exercises.first?.sets.first?.targetWeight == 50)
    }

    @Test func finishConfirmationBecomesInvalidWhenAnySetValueChanges() throws {
        let fixture = try makeOrdinaryWorkout(firstCompleted: true)
        defer { fixture.cleanupDefaults() }
        let service = makeService(
            container: fixture.container,
            defaults: fixture.defaults,
            finishEffects: noOpFinishEffects
        )
        let preview = try service.finishPreview()
        let firstSetID = fixture.firstSetID
        let edited = try #require(fixture.context.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.id == firstSetID }
        )).first)
        edited.weight = 125
        try fixture.context.save()

        do {
            try service.finishWorkout(expected: preview, exertion: 8)
            Issue.record("Expected a stale finish confirmation to be rejected.")
        } catch let error as ForgeFitActiveWorkoutCommandError {
            #expect(error.message.contains("changed while Siri was confirming"))
        }
        #expect(fixture.workout.endedAt == nil)
    }

    private func makeOrdinaryWorkout(
        firstCompleted: Bool = false
    ) throws -> OrdinaryFixture {
        let (container, context) = try TestStore.make()
        let (defaults, defaultsSuiteName) = try makeDefaults()
        let exerciseID = UUID(uuidString: "00000000-0000-7000-8000-00000000D121")!
        let first = SetModel(
            userID: userID,
            position: 0,
            setType: .working,
            reps: 10,
            weight: 100,
            completedAt: firstCompleted ? now.addingTimeInterval(-60) : nil
        )
        let second = SetModel(
            userID: userID,
            position: 1,
            setType: .working,
            reps: 6,
            weight: 110
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Strength Day",
            startedAt: now.addingTimeInterval(-600),
            sourceDevice: "iphone",
            exercises: [WorkoutExerciseModel(
                userID: userID,
                exerciseID: exerciseID,
                restSeconds: 0,
                sets: [first, second]
            )]
        )
        context.insert(ExerciseLibraryModel(id: exerciseID, name: "Bench Press"))
        context.insert(workout)
        try context.save()
        return OrdinaryFixture(
            container: container,
            context: context,
            defaults: defaults,
            defaultsSuiteName: defaultsSuiteName,
            workout: workout,
            firstSetID: first.id,
            secondSetID: second.id
        )
    }

    private func makeService(
        container: ModelContainer,
        defaults: UserDefaults,
        finishEffects: WorkoutFinisher.FinishEffects? = nil
    ) -> ForgeFitActiveWorkoutIntentService {
        ForgeFitActiveWorkoutIntentService(
            container: container,
            defaults: defaults,
            now: { now },
            finishEffects: finishEffects,
            publishesExternalSurfaces: false
        )
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "ForgeFitActiveWorkoutIntentServiceTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    private var noOpFinishEffects: WorkoutFinisher.FinishEffects {
        WorkoutFinisher.FinishEffects(
            scheduleHealthKitSave: { _ in },
            scheduleHeartRateSamples: { _ in },
            sendWorkoutFinishedToWatch: { _ in },
            publishWatchState: {},
            noteLogDataChanged: {}
        )
    }
}

@MainActor
private struct OrdinaryFixture {
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let workout: WorkoutModel
    let firstSetID: UUID
    let secondSetID: UUID

    func cleanupDefaults() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}
