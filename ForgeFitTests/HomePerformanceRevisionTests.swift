import Combine
import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
private final class ControlledRenderSettlement {
    private(set) var source: RenderPerformanceInvalidationSource?
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(for source: RenderPerformanceInvalidationSource) async {
        self.source = source
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite("Home performance cache invalidation")
struct HomePerformanceRevisionTests {
    @Test("Memo computes once until a semantic input changes")
    func memoCoalescesEquivalentBodyPasses() {
        let memo = Memo<Int, Int>()
        var computations = 0

        #expect(memo(7) { computations += 1; return 41 } == 41)
        #expect(memo(7) { computations += 1; return 99 } == 41)
        #expect(computations == 1)
        #expect(memo(8) { computations += 1; return 99 } == 99)
        #expect(computations == 2)
    }

    @Test("Editing an older completed workout invalidates suggestions")
    func olderWorkoutMutationInvalidatesSuggestion() {
        let before = HomePerformanceRevision.suggestion(
            persistenceRevision: 2,
            routineCount: 1,
            workoutCount: 2,
            alternationCount: 0,
            folderCount: 0,
            activeMicrocycle: "",
            activeMesocycle: ""
        )
        let after = HomePerformanceRevision.suggestion(
            persistenceRevision: 3,
            routineCount: 1,
            workoutCount: 2,
            alternationCount: 0,
            folderCount: 0,
            activeMicrocycle: "",
            activeMesocycle: ""
        )

        #expect(before != after)
    }

    @Test("Nested set and cardio edits invalidate a feed presentation")
    func nestedWorkoutMutationInvalidatesFeed() {
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 5,
            weight: 100,
            completedAt: Date()
        )
        let exercise = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            sets: [set]
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutExerciseID: exercise.id,
            modality: "running",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            durationSeconds: 100,
            distanceMeters: 500
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            endedAt: Date(),
            exercises: [exercise],
            cardioSessions: [session]
        )
        let initial = HomePerformanceRevision.workoutFeed(
            workout: workout,
            exerciseCatalogRevision: 0,
            weightUnit: .kg,
            distanceUnit: .km
        )

        set.reps = 8
        workout.updatedAt = Date(timeIntervalSince1970: 300)
        let setEdited = HomePerformanceRevision.workoutFeed(
            workout: workout,
            exerciseCatalogRevision: 0,
            weightUnit: .kg,
            distanceUnit: .km
        )
        session.distanceMeters = 750
        workout.updatedAt = Date(timeIntervalSince1970: 400)
        let cardioEdited = HomePerformanceRevision.workoutFeed(
            workout: workout,
            exerciseCatalogRevision: 0,
            weightUnit: .kg,
            distanceUnit: .km
        )

        #expect(initial != setEdited)
        #expect(setEdited != cardioEdited)
    }

    @Test("Quick-start eligibility invalidates without reparsing unrelated state")
    func quickStartEligibilityIsSemantic() {
        let initial = HomePerformanceRevision.quickStart(
            json: "[]",
            persistenceRevision: 10,
            routineCount: 1
        )
        let archived = HomePerformanceRevision.quickStart(
            json: "[]",
            persistenceRevision: 11,
            routineCount: 1
        )
        #expect(initial != archived)
    }

    @Test("Suggestion reason invalidates at a local-day boundary")
    func suggestionRelativeDayInvalidates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let beforeMidnight = Date(timeIntervalSince1970: 86_399)
        let afterMidnight = Date(timeIntervalSince1970: 86_401)

        let before = HomePerformanceRevision.suggestion(
            persistenceRevision: 0,
            routineCount: 1,
            workoutCount: 0,
            alternationCount: 0,
            folderCount: 0,
            activeMicrocycle: "",
            activeMesocycle: "",
            now: beforeMidnight,
            calendar: calendar
        )
        let after = HomePerformanceRevision.suggestion(
            persistenceRevision: 0,
            routineCount: 1,
            workoutCount: 0,
            alternationCount: 0,
            folderCount: 0,
            activeMicrocycle: "",
            activeMesocycle: "",
            now: afterMidnight,
            calendar: calendar
        )

        #expect(before != after)
    }

    @Test("Save routing invalidates only affected render domains")
    func saveRoutingIsDomainSpecific() {
        let routineChild = RenderPerformanceInvalidationPolicy.invalidation(
            for: ["RoutineExerciseModel"]
        )
        #expect(routineChild.contains(.homeSuggestion))
        #expect(routineChild.contains(.homeQuickStart))
        #expect(routineChild.contains(.routineLibrary))
        #expect(!routineChild.contains(.historyAnalytics))

        let liveSet = RenderPerformanceInvalidationPolicy.invalidation(for: ["SetModel"])
        #expect(liveSet == [.historyAnalytics])

        let exercise = RenderPerformanceInvalidationPolicy.invalidation(
            for: ["ExerciseLibraryModel"]
        )
        #expect(exercise == [.exerciseCatalog, .historyAnalytics])
    }

    @Test("Logger-time invalidations coalesce without changing revisions")
    func liveWorkoutInvalidationsCoalesce() {
        let buffer = RenderPerformanceInvalidationBuffer()
        var revisions = RenderPerformanceRevisions()

        let first = buffer.receive(.historyAnalytics, isDeferred: true)
        let second = buffer.receive(.routineLibrary, isDeferred: true)
        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(revisions == RenderPerformanceRevisions())

        revisions.record(buffer.release())
        #expect(revisions.historyAnalytics == 1)
        #expect(revisions.routineLibrary == 1)
    }

    @Test("CloudKit changes conservatively invalidate every render domain")
    func remoteStoreChangesInvalidateEveryDomain() {
        let invalidation = RenderPerformanceInvalidationPolicy.remoteStoreInvalidation

        #expect(invalidation == .all)
        #expect(invalidation.contains(.homeSuggestion))
        #expect(invalidation.contains(.homeQuickStart))
        #expect(invalidation.contains(.historyAnalytics))
        #expect(invalidation.contains(.exerciseCatalog))
        #expect(invalidation.contains(.routineLibrary))
        #expect(invalidation.contains(.archive))
    }

    @Test("A hidden remote change settles before reveal exposes its revision")
    func hiddenSurfaceDefersHeavyCacheRevisionUntilRemoteStoreSettles() async {
        let settlement = ControlledRenderSettlement()
        let controller = RenderPerformanceRevisionController { source in
            await settlement.wait(for: source)
        }

        controller.receive(
            [.routineLibrary, .archive],
            source: .remoteStoreChange,
            surfaceIsActive: false
        )

        #expect(controller.committedRevisions.routineLibrary == 0)
        #expect(controller.committedRevisions.archive == 0)
        #expect(controller.revisions(forActiveSurface: false).routineLibrary == 0)
        #expect(controller.revisions(forActiveSurface: true).routineLibrary == 0)

        for _ in 0..<100 where settlement.source == nil { await Task.yield() }
        #expect(settlement.source == .remoteStoreChange)

        settlement.release()
        for _ in 0..<100 where controller.revisions(forActiveSurface: true).routineLibrary == 0 {
            await Task.yield()
        }

        #expect(controller.committedRevisions.routineLibrary == 0)
        #expect(controller.revisions(forActiveSurface: true).routineLibrary == 1)
        #expect(controller.revisions(forActiveSurface: true).archive == 1)

        controller.setSurfaceActive(true)

        #expect(controller.committedRevisions.routineLibrary == 1)
        #expect(controller.committedRevisions.archive == 1)
        #expect(controller.revisions(forActiveSurface: true).routineLibrary == 1)
    }

    @Test("External-context revisions publish only after propagation settles")
    func externalContextRevisionWaitsForPropagation() async {
        let settlement = ControlledRenderSettlement()
        let controller = RenderPerformanceRevisionController { source in
            await settlement.wait(for: source)
        }
        controller.setSurfaceActive(true)
        controller.receive(
            .routineLibrary,
            source: .externalContextSave,
            surfaceIsActive: true
        )

        for _ in 0..<100 where settlement.source == nil { await Task.yield() }
        #expect(settlement.source == .externalContextSave)
        #expect(controller.committedRevisions.routineLibrary == 0)

        settlement.release()
        for _ in 0..<100 where controller.committedRevisions.routineLibrary == 0 {
            await Task.yield()
        }
        #expect(controller.committedRevisions.routineLibrary == 1)
    }

    @Test("An unrelated context is rejected before observer delivery")
    func contextSpecificPublisherPrefiltersUnrelatedStores() throws {
        let firstStore = try TestStore.makeContainer()
        let secondStore = try TestStore.makeContainer()
        let expectedContext = ModelContext(firstStore)
        let unrelatedContext = ModelContext(secondStore)
        var deliveries = 0
        let subscription = NotificationCenter.default.publisher(
            for: ModelContext.didSave,
            object: expectedContext
        ).sink { _ in deliveries += 1 }
        defer { subscription.cancel() }

        NotificationCenter.default.post(name: ModelContext.didSave, object: unrelatedContext)
        #expect(deliveries == 0)
        NotificationCenter.default.post(name: ModelContext.didSave, object: expectedContext)
        #expect(deliveries == 1)
    }

    @Test("A private-context same-count edit rebuilds from durable state")
    func privateContextSameCountEditUsesSettledRevision() throws {
        let store = try TestStore.makeContainer()
        let sourceContext = ModelContext(store)
        sourceContext.autosaveEnabled = false
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "Original")
        sourceContext.insert(routine)
        try sourceContext.save()

        let memo = Memo<RoutineLibraryPerformanceKey, RoutineLibraryPerformanceSnapshot>()
        let beforeRoutines = try sourceContext.fetch(FetchDescriptor<RoutineModel>())
        let beforeKey = RoutineLibraryPerformanceKey(
            persistenceRevision: 0,
            routineCount: beforeRoutines.count,
            folderCount: 0,
            alternationCount: 0,
            workoutCount: 0
        )
        let before = memo(beforeKey) {
            RoutineLibraryPerformanceSnapshot.make(
                routines: beforeRoutines,
                folders: [],
                alternations: [],
                workouts: [],
                generation: beforeKey.generation
            )
        }
        #expect(before.activeRoutines.map(\.id) == [routine.id])

        let transaction = ModelContext(store)
        transaction.autosaveEnabled = false
        let routineID = routine.id
        let edited = try #require(transaction.fetch(
            FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == routineID })
        ).first)
        edited.archivedAt = Date(timeIntervalSince1970: 500)
        edited.updatedAt = Date(timeIntervalSince1970: 500)
        try transaction.save()

        let notification = Notification(
            name: ModelContext.didSave,
            object: transaction,
            userInfo: [
                ModelContext.NotificationKey.updatedIdentifiers.rawValue: [edited.persistentModelID]
            ]
        )
        let invalidation = RenderPerformanceInvalidationPolicy.invalidation(
            from: notification,
            matching: store
        )
        #expect(invalidation.contains(.routineLibrary))

        let freshContext = ModelContext(store)
        let settledRoutines = try freshContext.fetch(FetchDescriptor<RoutineModel>())
        let afterKey = RoutineLibraryPerformanceKey(
            persistenceRevision: 1,
            routineCount: settledRoutines.count,
            folderCount: 0,
            alternationCount: 0,
            workoutCount: 0
        )
        let after = memo(afterKey) {
            RoutineLibraryPerformanceSnapshot.make(
                routines: settledRoutines,
                folders: [],
                alternations: [],
                workouts: [],
                generation: afterKey.generation
            )
        }

        #expect(beforeKey.routineCount == afterKey.routineCount)
        #expect(after.activeRoutines.isEmpty)
    }

    @Test("A non-newest terminal workout mutation invalidates lifecycle work")
    func olderTerminalWorkoutMutationInvalidatesLifecycleRevision() {
        let older = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: UUID(),
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let newer = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: UUID(),
            startedAt: Date(timeIntervalSince1970: 400),
            endedAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: 600)
        )
        let before = TerminalWorkoutLifecycleRevision.make([newer, older])

        older.routineID = UUID()
        older.updatedAt = Date(timeIntervalSince1970: 350)
        let after = TerminalWorkoutLifecycleRevision.make([newer, older])

        #expect(before != after)
    }
}
