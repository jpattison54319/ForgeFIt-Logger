import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
@Suite(.serialized)
struct DeferredWorkoutEnrichmentTests {
    @Test func importedDistanceIsMarkedAsHealthKitProvenance() async throws {
        let (container, context) = try TestStore.make()
        let start = Date.now.addingTimeInterval(-600)
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            liveStartedAt: start,
            endedAt: start
        )
        context.insert(session)
        try context.save()
        let request = DeferredWorkoutEnrichmentCoordinator.SessionRequest(
            sessionID: session.id,
            start: start,
            end: start,
            modality: .run,
            fallbackAvgHR: nil,
            fallbackMaxHR: nil,
            importsDistance: true,
            providesGPSDistance: false,
            hadManualIntervalPlan: true
        )

        await DeferredWorkoutEnrichmentCoordinator.shared.enrichSession(
            request,
            container: container,
            snapshot: { CardioSnapshot(distanceMeters: 5_000) }
        )

        let fresh = ModelContext(container)
        let id = session.id
        let restored = try #require(fresh.fetch(
            FetchDescriptor<CardioSessionModel>(predicate: #Predicate { $0.id == id })
        ).first)
        #expect(restored.distanceMeters == 5_000)
        #expect(restored.distanceSource == .healthKit)
    }

    @Test func hardDeleteWhileHealthQueryIsSuspendedCannotResurrectWorkout() async throws {
        let (container, context) = try TestStore.make()
        let workout = finishedWorkout(in: context)
        let id = workout.id
        let gate = SnapshotGate(value: CardioSnapshot(avgHR: 145, maxHR: 170, activeEnergyKcal: 300))
        let request = DeferredWorkoutEnrichmentCoordinator.WorkoutRequest(
            workoutID: id,
            start: workout.startedAt,
            end: workout.endedAt!
        )

        let task = Task { @MainActor in
            await DeferredWorkoutEnrichmentCoordinator.shared.enrichWorkout(
                request,
                container: container,
                snapshot: { await gate.provide() }
            )
        }
        await gate.waitUntilStarted()
        context.delete(workout)
        try context.save()
        await gate.release()
        await task.value

        let fresh = ModelContext(container)
        let rows = try fresh.fetch(FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id }))
        #expect(rows.isEmpty)
    }

    @Test func cancellationBeforeRefetchLeavesFinishedWorkoutUntouched() async throws {
        let (container, context) = try TestStore.make()
        let workout = finishedWorkout(in: context)
        let id = workout.id
        let gate = SnapshotGate(value: CardioSnapshot(avgHR: 145, maxHR: 170, activeEnergyKcal: 300))
        let request = DeferredWorkoutEnrichmentCoordinator.WorkoutRequest(
            workoutID: id,
            start: workout.startedAt,
            end: workout.endedAt!
        )

        let task = Task { @MainActor in
            await DeferredWorkoutEnrichmentCoordinator.shared.enrichWorkout(
                request,
                container: container,
                snapshot: { await gate.provide() }
            )
        }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        await task.value

        let fresh = ModelContext(container)
        let row = try #require(fresh.fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id })
        ).first)
        #expect(row.avgHR == nil)
        #expect(row.maxHR == nil)
        #expect(row.activeEnergyKcal == nil)
    }

    @Test func resetRegistryCancellationStopsEveryScheduledFill() async throws {
        let (container, context) = try TestStore.make()
        let workout = finishedWorkout(in: context)
        let id = workout.id
        let gate = SnapshotGate(value: CardioSnapshot(avgHR: 155))
        let request = DeferredWorkoutEnrichmentCoordinator.WorkoutRequest(
            workoutID: id,
            start: workout.startedAt,
            end: workout.endedAt!
        )

        let task = DeferredWorkoutEnrichmentCoordinator.shared.scheduleWorkout(
            request,
            container: container,
            snapshot: { await gate.provide() }
        )
        await gate.waitUntilStarted()
        DeferredWorkoutEnrichmentCoordinator.shared.cancelAll()
        await gate.release()
        await task.value

        let fresh = ModelContext(container)
        let row = try #require(fresh.fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id })
        ).first)
        #expect(row.avgHR == nil)
    }

    @Test func softDeletedWorkoutIsRejectedAtRefetchBoundary() async throws {
        let (container, context) = try TestStore.make()
        let workout = finishedWorkout(in: context)
        let id = workout.id
        let gate = SnapshotGate(value: CardioSnapshot(avgHR: 145, maxHR: 170, activeEnergyKcal: 300))
        let request = DeferredWorkoutEnrichmentCoordinator.WorkoutRequest(
            workoutID: id,
            start: workout.startedAt,
            end: workout.endedAt!
        )

        let task = Task { @MainActor in
            await DeferredWorkoutEnrichmentCoordinator.shared.enrichWorkout(
                request,
                container: container,
                snapshot: { await gate.provide() }
            )
        }
        await gate.waitUntilStarted()
        workout.deletedAt = .now
        try context.save()
        await gate.release()
        await task.value

        let fresh = ModelContext(container)
        let row = try #require(fresh.fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id })
        ).first)
        #expect(row.deletedAt != nil)
        #expect(row.avgHR == nil)
    }

    private func finishedWorkout(in context: ModelContext) -> WorkoutModel {
        let start = Date.now.addingTimeInterval(-600)
        let workout = WorkoutModel(userID: ForgeFitDemo.userID, startedAt: start)
        workout.endedAt = start.addingTimeInterval(600)
        context.insert(workout)
        try? context.save()
        return workout
    }
}

private actor SnapshotGate {
    private let value: CardioSnapshot
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(value: CardioSnapshot) {
        self.value = value
    }

    func provide() async -> CardioSnapshot {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return value
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
