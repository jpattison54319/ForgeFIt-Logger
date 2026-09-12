import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite(.serialized)
struct WatchDeliveryIntegrationTests {
    @Test func legacyQueuedStartsAndExpiredRequestsCreateNoWorkout() throws {
        let (container, _) = try TestStore.make()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        for command in [WatchCommand.startEmpty, .startRoutine(routineID: UUID()), .startNextTrackedWorkout] {
            link.handle(command)
            let request = WatchStartRequest(issuedAt: Date().addingTimeInterval(-9), command: command)
            if case .unavailable = link.handleStartRequest(request).result {} else { Issue.record("Expired start was accepted") }
        }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WorkoutModel>()) == 0)
    }

    @Test(arguments: [false, true])
    func aStartPersistsOnceAndCannotReplayAfterFinishOrLinkRestart(discard: Bool) throws {
        let (container, _) = try TestStore.make()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        let request = WatchStartRequest(command: .startEmpty)
        #expect(link.handleStartRequest(request).result == .started(title: "Workout"))
        let reader = ModelContext(container)
        let workout = try #require(reader.fetch(FetchDescriptor<WorkoutModel>()).first)
        #expect(workout.id == request.id)
        let restarted = WatchLink()
        restarted.configureIfNeeded(container: container)
        if case .activeWorkout = restarted.handleStartRequest(request).result {} else { Issue.record("Retry did not identify the existing workout") }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WorkoutModel>()) == 1)
        if discard { workout.deletedAt = Date() }
        else { workout.endedAt = Date() }
        try reader.save()
        if case .unavailable = restarted.handleStartRequest(request).result {} else { Issue.record("Ended workout was replayed") }
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WorkoutModel>()) == 1)
        #expect(restarted.makeSyncReply(to: WatchSyncRequest()).metadata?.workoutID == nil)
    }

    @Test func aRequestThatExpiresBeforeCommitLeavesNoGraphForALaterSave() throws {
        let (container, context) = try TestStore.make()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        let request = WatchStartRequest(issuedAt: Date().addingTimeInterval(-9), command: .startEmpty)
        // Simulate receipt before the deadline, followed by a delayed commit.
        let reply = link.handleStartRequest(request, now: request.issuedAt)
        if case .unavailable = reply.result {} else { Issue.record("Expired commit was accepted") }
        try context.save()
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WorkoutModel>()) == 0)
    }

    @Test func aFreshStartCannotReplaceAnotherActiveWorkout() throws {
        let (container, context) = try TestStore.make()
        let workout = WorkoutModel(userID: UUID(), title: "Already training", startedAt: Date())
        context.insert(workout)
        try context.save()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        let result = link.handleStartRequest(WatchStartRequest(command: .startEmpty))
        #expect(result.result == .activeWorkout(title: "Already training"))
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<WorkoutModel>()) == 1)
    }

    @Test func routineStartWithThousandWorkoutHistoryMeetsTheRequestDeadline() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let userID = ForgeFitDemo.userID
        let exercise = ExerciseLibraryModel(name: "Delivery timing press", equipment: "machine")
        let routine = RoutineModel(userID: userID, name: "Delivery timing routine", exercises: [
            RoutineExerciseModel(userID: userID, exerciseID: exercise.id, sets: [
                RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetWeight: 70)
            ])
        ])
        context.insert(exercise)
        context.insert(routine)
        for index in 0..<1_005 {
            let end = Date().addingTimeInterval(Double(-index - 1) * 86_400)
            let history = WorkoutModel(userID: userID, startedAt: end.addingTimeInterval(-1_800), endedAt: end,
                exercises: [WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: (0..<3).map {
                    SetModel(userID: userID, position: $0, reps: 8, weight: 70, completedAt: end)
                })])
            context.insert(history)
        }
        try context.save()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        let request = WatchStartRequest(command: .startRoutine(routineID: routine.id))
        let clock = ContinuousClock()
        let start = clock.now
        let reply = link.handleStartRequest(request)
        let elapsed = start.duration(to: clock.now)
        print("Watch routine start with 1005 workouts: \(elapsed)")
        #expect(elapsed < .seconds(WatchStartRequest.maximumAge))
        #expect(reply.result == .started(title: routine.name))
        let reader = ModelContext(container)
        let snapshot = try #require(WatchLink().buildContext(in: reader).workout)
        #expect(snapshot.workoutID == request.id)
        #expect(snapshot.exercises.first?.name == exercise.name)
        #expect(snapshot.exercises.first?.sets.first?.reps == 8)
        #expect(snapshot.exercises.first?.sets.first?.weightKg == 70)
    }

    @Test func delayedMetricsCannotReplaceLiveHeartRateOrDistance() throws {
        let (container, context) = try TestStore.make()
        let workout = WorkoutModel(userID: UUID(), startedAt: Date())
        context.insert(workout)
        try context.save()
        let link = WatchLink()
        link.configureIfNeeded(container: container)
        LiveMetricsHub.shared.clearLiveMetrics()
        defer { LiveMetricsHub.shared.clearLiveMetrics() }
        let now = Date(), stream = UUID()
        let latest = WatchLiveMetrics(workoutID: workout.id, heartRate: 140, distanceMeters: 200,
                                      asOf: now, streamID: stream, sequence: 2, sentAt: now)
        link.handle(.liveMetrics(latest))
        var old = latest
        old.sequence = 1
        old.heartRate = 100
        old.distanceMeters = 50
        link.handle(.liveMetrics(old))
        link.handle(.liveMetrics(latest))
        #expect(LiveMetricsHub.shared.liveMetrics?.heartRate == 140)
        #expect(LiveMetricsHub.shared.liveMetrics?.distanceMeters == 200)
        #expect(!LiveMetricsHub.shared.mayAcceptFromWatch(latest))
        var otherWorkout = latest
        otherWorkout.workoutID = UUID()
        otherWorkout.heartRate = 180
        link.handle(.liveMetrics(otherWorkout))
        #expect(LiveMetricsHub.shared.liveMetrics?.heartRate == 140)
    }
}
