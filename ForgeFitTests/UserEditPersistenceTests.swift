import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct UserEditPersistenceTests {
    @Test func routineRenameIsVisibleFromAFreshContextAfterCommit() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Push 1"
        )
        context.insert(routine)
        try context.save()

        let renamedAt = Date.now.addingTimeInterval(5)
        routine.name = "Push 1 + mile"
        routine.updatedAt = renamedAt

        #expect(context.saveUserChanges())

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let routineID = routine.id
        let persisted = try #require(verificationContext.fetch(
            FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == routineID })
        ).first)
        #expect(persisted.name == "Push 1 + mile")
        #expect(persisted.updatedAt == renamedAt)
    }

    @Test func failedUserOperationKeepsAnExactRetryAndCompletion() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let center = PersistentChangeSaveCenter()
        var attempts = 0
        var completions = 0

        let initiallySucceeded = center.perform({
            attempts += 1
            if attempts == 1 { throw ExpectedFailure.firstAttempt }
        }, onSuccess: {
            completions += 1
        })

        #expect(!initiallySucceeded)
        #expect(center.failure != nil)
        #expect(attempts == 1)
        #expect(completions == 0)

        // Exercise the worst-case SwiftUI ordering: the alert binding is set
        // false before its Retry button action runs. The retained operation
        // must still be available to that action.
        center.endAlertPresentation()
        center.retry()
        // `retry()` deliberately yields one main-actor turn so an alert can
        // finish dismissing before a second failure is presented. Sleeping
        // briefly lets that queued turn run without depending on executor
        // ordering between two consecutive `Task.yield()` calls.
        try await Task.sleep(for: .milliseconds(20))

        #expect(center.failure == nil)
        #expect(attempts == 2)
        #expect(completions == 1)
    }

    @Test func reportedTerminalFailureRetriesBeforeCompleting() async throws {
        let center = PersistentChangeSaveCenter()
        var attempts = 0
        var completions = 0

        let initiallySucceeded = center.performReportingFailure({
            attempts += 1
            return attempts == 1 ? "Store unavailable" : nil
        }, onSuccess: {
            completions += 1
        })

        #expect(!initiallySucceeded)
        #expect(center.failure?.message == "Store unavailable")
        #expect(completions == 0)

        center.endAlertPresentation()
        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        #expect(center.failure == nil)
        #expect(attempts == 2)
        #expect(completions == 1)
    }

    @Test func routineCardioGoalIsVisibleFromAFreshContextAfterBuilderCommit() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let target = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            targetDurationSeconds: 1_800
        )
        let routineExercise = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            sets: [target]
        )
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Run Day",
            exercises: [routineExercise]
        )
        context.insert(routine)
        try context.save()

        let plan = IntervalPlan(
            steps: [],
            goal: .init(kind: .distance, value: 5_000)
        )
        #expect(RoutineIntervalPlanPersistence.apply(
            plan.encodedJSON(),
            to: routineExercise,
            in: context
        ))

        let verificationContext = ModelContext(container)
        verificationContext.autosaveEnabled = false
        let routineExerciseID = routineExercise.id
        let persisted = try #require(verificationContext.fetch(
            FetchDescriptor<RoutineExerciseModel>(
                predicate: #Predicate { $0.id == routineExerciseID }
            )
        ).first)
        #expect(IntervalPlan.decode(from: persisted.intervalPlanJSON)?.goal?.kind == .distance)
        #expect(IntervalPlan.decode(from: persisted.intervalPlanJSON)?.goal?.value == 5_000)
        #expect(persisted.sets.first?.targetDistanceMeters == 5_000)
        #expect(persisted.sets.first?.targetDurationSeconds == nil)
    }

    @Test func failedRoutineCardioGoalRestoresThenRetriesTheExactProjection() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let target = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            targetDurationSeconds: 1_800
        )
        let routineExercise = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            sets: [target]
        )
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Run Day",
            exercises: [routineExercise]
        )
        context.insert(routine)
        try context.save()
        let center = PersistentChangeSaveCenter()
        var attempts = 0
        let plan = IntervalPlan(
            steps: [],
            goal: .init(kind: .distance, value: 5_000)
        )

        let didApplyGoal = RoutineIntervalPlanPersistence.apply(
            plan.encodedJSON(),
            to: routineExercise,
            in: context,
            saveCenter: center,
            save: { saveContext in
                attempts += 1
                if attempts == 1 { throw ExpectedFailure.firstAttempt }
                try saveContext.save()
            }
        )
        #expect(!didApplyGoal)
        #expect(routineExercise.intervalPlanJSON == nil)
        #expect(target.targetDurationSeconds == 1_800)
        #expect(target.targetDistanceMeters == nil)

        // A later unrelated save must not smuggle the failed goal into the
        // store. Retry then reapplies the exact requested projection.
        try context.save()
        var verificationContext = ModelContext(container)
        let routineExerciseID = routineExercise.id
        var persisted = try #require(verificationContext.fetch(
            FetchDescriptor<RoutineExerciseModel>(
                predicate: #Predicate { $0.id == routineExerciseID }
            )
        ).first)
        #expect(persisted.intervalPlanJSON == nil)
        #expect(persisted.sets.first?.targetDurationSeconds == 1_800)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        verificationContext = ModelContext(container)
        persisted = try #require(verificationContext.fetch(
            FetchDescriptor<RoutineExerciseModel>(
                predicate: #Predicate { $0.id == routineExerciseID }
            )
        ).first)
        #expect(attempts == 2)
        #expect(IntervalPlan.decode(from: persisted.intervalPlanJSON)?.goal?.kind == .distance)
        #expect(persisted.sets.first?.targetDistanceMeters == 5_000)
        #expect(persisted.sets.first?.targetDurationSeconds == nil)
    }

    @Test func failedLiveCardioPlanEditRestoresAndKeepsBuilderUncommittedUntilRetry() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            intervalPlanJSON: "{\"mode\":\"open\"}"
        )
        context.insert(workoutExercise)
        try context.save()
        let originalUpdatedAt = workoutExercise.updatedAt
        let center = PersistentChangeSaveCenter()
        var saves = 0
        var commits = 0

        let didApply = WorkoutIntervalPlanPersistence.apply(
            "{\"mode\":\"zone\",\"zone\":2}",
            to: workoutExercise,
            in: context,
            saveCenter: center,
            save: { saveContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try saveContext.save()
            },
            onCommit: { commits += 1 }
        )
        #expect(!didApply)
        #expect(commits == 0)
        #expect(workoutExercise.intervalPlanJSON == "{\"mode\":\"open\"}")
        #expect(workoutExercise.updatedAt == originalUpdatedAt)
        try context.save()
        var persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<WorkoutExerciseModel>()).first
        )
        #expect(persisted.intervalPlanJSON == "{\"mode\":\"open\"}")

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<WorkoutExerciseModel>()).first
        )
        #expect(saves == 2)
        #expect(commits == 1)
        #expect(persisted.intervalPlanJSON == "{\"mode\":\"zone\",\"zone\":2}")
    }

    @Test func failedWorkoutStartLeaksNoActiveRowAndRetryCommitsExactlyOne() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let center = PersistentChangeSaveCenter()
        var attempts = 0
        var committedWorkoutID: UUID?

        let immediate = WorkoutFactory.startEmpty(
            in: context,
            saveCenter: center,
            save: { isolatedContext in
                attempts += 1
                if attempts == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { committedWorkoutID = $0.id }
        )

        #expect(immediate == nil)
        #expect(center.failure != nil)
        #expect(attempts == 1)
        #expect(committedWorkoutID == nil)

        let beforeRetry = ModelContext(container)
        beforeRetry.autosaveEnabled = false
        #expect(try beforeRetry.fetch(FetchDescriptor<WorkoutModel>()).isEmpty)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        let afterRetry = ModelContext(container)
        afterRetry.autosaveEnabled = false
        let persisted = try afterRetry.fetch(FetchDescriptor<WorkoutModel>())
        #expect(attempts == 2)
        #expect(center.failure == nil)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == committedWorkoutID)
    }

    @Test func failedRoutineCreationStaysInvisibleAndRetryOpensExactlyOneRoutine() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let center = PersistentChangeSaveCenter()
        let attempt = RoutineCreationAttempt(
            name: "New Routine",
            folderID: nil,
            position: 0,
            in: context
        )
        var saves = 0
        var openedRoutineID: UUID?

        let didCreateRoutine = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { openedRoutineID = $0.id }
        )
        #expect(!didCreateRoutine)
        #expect(openedRoutineID == nil)
        #expect(try ModelContext(container).fetch(FetchDescriptor<RoutineModel>()).isEmpty)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        let persisted = try ModelContext(container).fetch(FetchDescriptor<RoutineModel>())
        #expect(saves == 2)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == attempt.id)
        #expect(persisted.first?.id == openedRoutineID)
    }

    @Test func failedRoutineDuplicateLeavesOnlySourceAndRetryCopiesFullPlanOnce() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let sourceSet = RoutineSetModel(
            userID: ForgeFitDemo.userID,
            position: 0,
            targetDurationSeconds: 1_200,
            targetDistanceMeters: 5_000,
            plannedMiniSetCount: 3,
            plannedMiniRepsJSON: "[3,3,3]"
        )
        let sourceExercise = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            intervalPlanJSON: "{\"goal\":\"distance\"}",
            sets: [sourceSet]
        )
        let source = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Engine",
            exercises: [sourceExercise]
        )
        context.insert(source)
        try context.save()

        let center = PersistentChangeSaveCenter()
        let attempt = RoutineCreationAttempt(
            duplicating: source,
            position: 1,
            in: context
        )
        var saves = 0
        let didDuplicate = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { _ in }
        )
        #expect(!didDuplicate)
        var persisted = try ModelContext(container).fetch(FetchDescriptor<RoutineModel>())
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == source.id)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        persisted = try ModelContext(container).fetch(FetchDescriptor<RoutineModel>())
        #expect(saves == 2)
        #expect(persisted.count == 2)
        let copy = try #require(persisted.first { $0.id == attempt.id })
        #expect(copy.name == "Engine Copy")
        #expect(copy.exercises.count == 1)
        #expect(copy.exercises.first?.id != sourceExercise.id)
        #expect(copy.exercises.first?.sets.first?.id != sourceSet.id)
        #expect(copy.exercises.first?.sets.first?.targetDurationSeconds == 1_200)
        #expect(copy.exercises.first?.sets.first?.targetDistanceMeters == 5_000)
        #expect(copy.exercises.first?.sets.first?.plannedMiniSetCount == 3)
        #expect(copy.exercises.first?.sets.first?.plannedMiniRepsJSON == "[3,3,3]")
    }

    @Test func failedFirstSubfolderCreationMovesNothingUntilExactRetryCommits() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let parent = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Base Phase",
            position: 0
        )
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Day A",
            folderID: parent.id,
            position: 0
        )
        context.insert(parent)
        context.insert(routine)
        try context.save()

        let center = PersistentChangeSaveCenter()
        let attempt = RoutineFolderCreationAttempt(
            name: "Week 1",
            position: 1,
            parentID: parent.id,
            in: context
        )
        var saves = 0
        var committedFolderID: UUID?
        let didCreateFolder = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { committedFolderID = $0.id }
        )
        #expect(!didCreateFolder)
        #expect(committedFolderID == nil)
        var fresh = ModelContext(container)
        #expect(try fresh.fetch(FetchDescriptor<RoutineFolderModel>()).count == 1)
        #expect(try #require(fresh.fetch(FetchDescriptor<RoutineModel>()).first).folderID == parent.id)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        fresh = ModelContext(container)
        let folders = try fresh.fetch(FetchDescriptor<RoutineFolderModel>())
        let movedRoutine = try #require(fresh.fetch(FetchDescriptor<RoutineModel>()).first)
        #expect(saves == 2)
        #expect(folders.count == 2)
        #expect(committedFolderID == attempt.id)
        #expect(movedRoutine.folderID == attempt.id)
    }

    @Test func failedFolderDeleteMovesNothingAndDefersExternalCommitEffectsUntilRetry() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let folder = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Phase",
            position: 0
        )
        let child = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Week 1",
            position: 0,
            parentID: folder.id
        )
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Day A",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(child)
        context.insert(routine)
        try context.save()

        let center = PersistentChangeSaveCenter()
        let attempt = RoutineFolderDeletionAttempt(folder: folder, in: context)
        var saves = 0
        var didRunCommitEffects = false
        let didDelete = attempt.commit(
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { didRunCommitEffects = true }
        )
        #expect(!didDelete)
        #expect(!didRunCommitEffects)
        var fresh = ModelContext(container)
        var persistedFolders = try fresh.fetch(FetchDescriptor<RoutineFolderModel>())
        var persistedRoutine = try #require(fresh.fetch(FetchDescriptor<RoutineModel>()).first)
        #expect(persistedFolders.first(where: { $0.id == folder.id })?.deletedAt == nil)
        #expect(persistedFolders.first(where: { $0.id == child.id })?.parentID == folder.id)
        #expect(persistedRoutine.folderID == folder.id)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        fresh = ModelContext(container)
        persistedFolders = try fresh.fetch(FetchDescriptor<RoutineFolderModel>())
        persistedRoutine = try #require(fresh.fetch(FetchDescriptor<RoutineModel>()).first)
        #expect(saves == 2)
        #expect(didRunCommitEffects)
        #expect(persistedFolders.first(where: { $0.id == folder.id })?.deletedAt != nil)
        #expect(persistedFolders.first(where: { $0.id == child.id })?.parentID == nil)
        #expect(persistedRoutine.folderID == nil)
    }

    @Test func failedCustomExerciseCreationHasNoResidueCallbackOrDuplicateOnRetry() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let center = PersistentChangeSaveCenter()
        let attempt = ExercisePersistenceAttempt(
            creatingName: "Atlantis Press",
            in: context
        )
        var saves = 0
        var callbackIDs: [UUID] = []
        let didCreate = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            mutate: { exercise, _ in
                exercise.name = "Atlantis Press"
                exercise.modality = .strength
                exercise.userModified = true
            },
            onCommit: { callbackIDs.append($0.id) }
        )
        #expect(!didCreate)
        #expect(callbackIDs.isEmpty)
        #expect(try ModelContext(container).fetch(FetchDescriptor<ExerciseLibraryModel>()).isEmpty)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        let persisted = try ModelContext(container).fetch(FetchDescriptor<ExerciseLibraryModel>())
        #expect(saves == 2)
        #expect(callbackIDs == [attempt.id])
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == attempt.id)
        #expect(persisted.first?.name == "Atlantis Press")
    }

    @Test func failedCustomExerciseEditLeavesSourceUntouchedUntilRetryCommitsAndMirrors() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let source = ExerciseLibraryModel(
            ownerID: ForgeFitDemo.userID,
            name: "Atlantis Press"
        )
        context.insert(source)
        try context.save()

        let center = PersistentChangeSaveCenter()
        let attempt = ExercisePersistenceAttempt(editing: source, in: context)
        var saves = 0
        var callbacks = 0
        let didEdit = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            mutate: { exercise, _ in
                exercise.name = "Atlantis Machine Press"
                exercise.updatedAt = Date(timeIntervalSinceReferenceDate: 42)
            },
            onCommit: { _ in
                callbacks += 1
                // Mirrors what CreateExerciseView does for an already-loaded
                // source-context model, and only runs after durable success.
                source.name = "Atlantis Machine Press"
                source.updatedAt = Date(timeIntervalSinceReferenceDate: 42)
            }
        )
        #expect(!didEdit)
        #expect(callbacks == 0)
        #expect(source.name == "Atlantis Press")
        var persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<ExerciseLibraryModel>()).first
        )
        #expect(persisted.name == "Atlantis Press")

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        #expect(saves == 2)
        #expect(callbacks == 1)
        #expect(source.name == "Atlantis Machine Press")
        persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<ExerciseLibraryModel>()).first
        )
        #expect(persisted.name == "Atlantis Machine Press")
    }

    @Test func failedYogaFlowCreationLeavesNoRowAndRetryCreatesExactlyOne() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let center = PersistentChangeSaveCenter()
        let attempt = YogaFlowCreationAttempt(
            name: "Recovery",
            styleRaw: YogaStyle.hatha.rawValue,
            planJSON: "{}",
            position: 0,
            in: context
        )
        var saves = 0
        var commits = 0

        let didCreateFlow = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { _ in commits += 1 }
        )
        #expect(!didCreateFlow)
        #expect(try ModelContext(container).fetch(FetchDescriptor<YogaFlowModel>()).isEmpty)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        let persisted = try ModelContext(container).fetch(FetchDescriptor<YogaFlowModel>())
        #expect(saves == 2)
        #expect(commits == 1)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == attempt.id)
    }

    @Test func failedLiveYogaPlanEditRestoresEveryProjectionUntilExactRetry() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let originalPlan = YogaFlowPlan(style: .hatha, steps: [
            .init(poseID: UUID(), name: "Child's Pose", holdSeconds: 30)
        ])
        let updatedPlan = YogaFlowPlan(style: .yin, steps: [
            .init(poseID: UUID(), name: "Butterfly", holdSeconds: 90)
        ])
        let workoutExercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            yogaFlowJSON: originalPlan.encodedJSON()
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: workoutExercise.id,
            modality: CardioSessionModel.yogaModality,
            durationSeconds: 30,
            yogaStyleRaw: YogaStyle.hatha.rawValue
        )
        context.insert(workoutExercise)
        context.insert(session)
        try context.save()
        let center = PersistentChangeSaveCenter()
        var saves = 0
        var commits = 0

        let didApply = WorkoutYogaPlanPersistence.apply(
            updatedPlan.encodedJSON(),
            to: workoutExercise,
            session: session,
            in: context,
            saveCenter: center,
            save: { saveContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try saveContext.save()
            },
            onCommit: { commits += 1 }
        )
        #expect(!didApply)
        #expect(commits == 0)
        #expect(YogaFlowPlan.decode(from: workoutExercise.yogaFlowJSON) == originalPlan)
        #expect(session.durationSeconds == 30)
        #expect(session.yogaStyleRaw == YogaStyle.hatha.rawValue)

        try context.save()
        var persistedSession = try #require(
            ModelContext(container).fetch(FetchDescriptor<CardioSessionModel>()).first
        )
        #expect(persistedSession.durationSeconds == 30)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        let verificationContext = ModelContext(container)
        let persistedExercise = try #require(
            verificationContext.fetch(FetchDescriptor<WorkoutExerciseModel>()).first
        )
        persistedSession = try #require(
            verificationContext.fetch(FetchDescriptor<CardioSessionModel>()).first
        )
        #expect(saves == 2)
        #expect(commits == 1)
        #expect(YogaFlowPlan.decode(from: persistedExercise.yogaFlowJSON) == updatedPlan)
        #expect(persistedSession.durationSeconds == 90)
        #expect(persistedSession.yogaStyleRaw == YogaStyle.yin.rawValue)
    }

    @Test func failedYogaFlowDeleteRestoresVisibilityBeforeAnyLaterSave() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let flow = YogaFlowModel(
            userID: ForgeFitDemo.userID,
            name: "Recovery",
            styleRaw: YogaStyle.hatha.rawValue,
            planJSON: "{}"
        )
        context.insert(flow)
        try context.save()
        let center = PersistentChangeSaveCenter()
        var saves = 0

        let didDeleteFlow = YogaFlowPersistence.softDelete(
            [flow],
            in: context,
            saveCenter: center,
            save: { saveContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try saveContext.save()
            }
        )
        #expect(!didDeleteFlow)
        #expect(flow.deletedAt == nil)

        try context.save()
        var persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<YogaFlowModel>()).first
        )
        #expect(persisted.deletedAt == nil)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))
        persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<YogaFlowModel>()).first
        )
        #expect(saves == 2)
        #expect(persisted.deletedAt != nil)
    }

    @Test func failedIntervalPresetCreationLeavesNoRowAndRetryCreatesExactlyOne() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let center = PersistentChangeSaveCenter()
        let attempt = IntervalPresetCreationAttempt(
            name: "Tempo repeats",
            planJSON: "{\"steps\":[]}",
            in: context
        )
        var saves = 0
        var committedPresetID: UUID?

        let didCreatePreset = attempt.commit(
            into: context,
            saveCenter: center,
            save: { isolatedContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try isolatedContext.save()
            },
            onCommit: { committedPresetID = $0.id }
        )
        #expect(!didCreatePreset)
        let beforeRetry = try ModelContext(container).fetch(FetchDescriptor<IntervalPresetModel>())
        #expect(beforeRetry.isEmpty)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))

        let persisted = try ModelContext(container).fetch(FetchDescriptor<IntervalPresetModel>())
        #expect(saves == 2)
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == attempt.id)
        #expect(persisted.first?.id == committedPresetID)
        #expect(persisted.first?.name == "Tempo repeats")
    }

    @Test func failedIntervalPresetDeleteRestoresVisibilityAndRetryPersists() async throws {
        enum ExpectedFailure: Error { case firstAttempt }

        let (container, context) = try TestStore.make()
        let preset = IntervalPresetModel(
            userID: ForgeFitDemo.userID,
            name: "Tempo repeats",
            planJSON: "{\"steps\":[]}"
        )
        context.insert(preset)
        try context.save()
        let originalUpdatedAt = preset.updatedAt
        let center = PersistentChangeSaveCenter()
        var saves = 0

        let didDeletePreset = IntervalPresetPersistence.softDelete(
            [preset],
            in: context,
            saveCenter: center,
            save: { saveContext in
                saves += 1
                if saves == 1 { throw ExpectedFailure.firstAttempt }
                try saveContext.save()
            }
        )
        #expect(!didDeletePreset)
        #expect(preset.deletedAt == nil)
        #expect(preset.updatedAt == originalUpdatedAt)

        try context.save()
        var persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<IntervalPresetModel>()).first
        )
        #expect(persisted.deletedAt == nil)

        center.retry()
        try await Task.sleep(for: .milliseconds(20))
        persisted = try #require(
            ModelContext(container).fetch(FetchDescriptor<IntervalPresetModel>()).first
        )
        #expect(saves == 2)
        #expect(persisted.deletedAt != nil)
    }
}
