import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct LiveWorkoutMetricsTests {
    @Test func editingCompletedSetImmediatelyRefreshesSetAndWorkoutMetrics() {
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
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            exercises: [exercise]
        )

        let metrics = LiveWorkoutMetrics()
        metrics.rebuild(from: workout)
        #expect(set.totalVolume == 500)
        #expect(workout.totalVolume == nil)
        #expect(metrics.volume == 500)
        #expect(metrics.completedSets == 1)

        set.reps = 8
        metrics.refresh(changedSet: set, in: workout)
        #expect(set.totalVolume == 800)
        #expect(workout.totalVolume == nil)
        #expect(metrics.volume == 800)

        set.weight = 120
        metrics.refresh(changedSet: set, in: workout)
        #expect(set.totalVolume == 960)
        #expect(workout.totalVolume == nil)
        #expect(metrics.volume == 960)
        #expect(set.estimated1RM != nil)
    }

    @Test func incrementalTotalsMatchTheFullScanAcrossCompletionAndEdits() {
        let visibleSets = (0..<40).map { index in
            SetModel(
                userID: ForgeFitDemo.userID,
                position: index,
                setType: index.isMultiple(of: 7) ? .warmup : .working,
                reps: 5 + index % 6,
                weight: Double(20 + index),
                completedAt: index.isMultiple(of: 3) ? nil : Date()
            )
        }
        let generatedSets = (0..<8).map { index in
            SetModel(
                userID: ForgeFitDemo.userID,
                position: index,
                reps: 10,
                weight: 10,
                completedAt: Date()
            )
        }
        let visible = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            sets: visibleSets
        )
        let generated = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: UUID(),
            generatedByWorkoutBlockID: UUID(),
            sets: generatedSets
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            endedAt: Date(),
            exercises: [visible, generated]
        )
        let metrics = LiveWorkoutMetrics()
        metrics.rebuild(from: workout)
        expectParity(metrics, workout: workout)

        for (index, set) in visibleSets.enumerated() {
            set.reps = (set.reps ?? 0) + 1
            if index.isMultiple(of: 4) {
                set.completedAt = set.completedAt == nil ? Date() : nil
            }
            metrics.refresh(changedSet: set, in: workout)
            expectParity(metrics, workout: workout)
        }

        visible.sets.removeLast()
        metrics.rebuild(from: workout)
        expectParity(metrics, workout: workout)
    }

    @Test func rebuildingAfterSaveDoesNotRedirtyTheContext() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        context.autosaveEnabled = false
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 5,
            weight: 100,
            completedAt: Date()
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            exercises: [WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: UUID(),
                sets: [set]
            )]
        )
        workout.recomputeTotalVolume()
        context.insert(workout)
        try context.save()
        #expect(!context.hasChanges)

        LiveWorkoutMetrics().rebuild(from: workout)

        #expect(!context.hasChanges)
    }

    @Test func metricRefreshLeavesActiveParentClockAloneButStampsHistoricalEdits() {
        let originalDate = Date(timeIntervalSince1970: 1_000)
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 5,
            weight: 100,
            completedAt: originalDate
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            updatedAt: originalDate,
            exercises: [WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: UUID(),
                sets: [set]
            )]
        )
        let metrics = LiveWorkoutMetrics()
        metrics.rebuild(from: workout)

        set.reps = 6
        metrics.refresh(changedSet: set, in: workout)
        #expect(workout.updatedAt == originalDate)
        #expect(workout.totalVolume == nil)

        workout.endedAt = originalDate.addingTimeInterval(60)
        set.reps = 7
        metrics.refresh(changedSet: set, in: workout)
        #expect(workout.updatedAt > originalDate)
        #expect(workout.totalVolume == 700)
    }

    @Test func activeFinishBoundaryRecomputesThePersistedAggregate() throws {
        let (container, context) = try TestStore.make()
        context.autosaveEnabled = false
        let set = SetModel(
            userID: ForgeFitDemo.userID,
            reps: 8,
            weight: 100,
            completedAt: Date()
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            exercises: [WorkoutExerciseModel(
                userID: ForgeFitDemo.userID,
                exerciseID: UUID(),
                sets: [set]
            )]
        )
        context.insert(workout)
        try context.save()

        let metrics = LiveWorkoutMetrics()
        metrics.rebuild(from: workout)
        #expect(metrics.volume == 800)
        #expect(workout.totalVolume == nil)

        // Mirrors ActiveWorkoutLoggerView's terminal boundary immediately
        // before WorkoutFinisher takes ownership of the isolated save.
        workout.recomputeTotalVolume()
        workout.endedAt = Date()
        WorkoutMutationContract.stampParentForNestedMutation(workout)
        #expect(context.saveUserChanges())

        let workoutID = workout.id
        let persisted = try #require(ModelContext(container).fetch(
            FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == workoutID })
        ).first)
        #expect(persisted.totalVolume == 800)
        #expect(persisted.endedAt != nil)
    }

    private func expectParity(_ metrics: LiveWorkoutMetrics, workout: WorkoutModel) {
        let allCompleted = workout.exercises.flatMap(\.sets).filter { $0.completedAt != nil }
        let expectedWorkoutVolume = allCompleted.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        let visibleCompleted = workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .flatMap(\.sets)
            .filter { $0.completedAt != nil && $0.setType.countsAsWorkingVolume }
        let expectedVisibleVolume = visibleCompleted.reduce(0) { $0 + ($1.totalVolume ?? 0) }
        let expectedSets = visibleCompleted.reduce(0) {
            $0 + VolumeMath.effectiveSetCount($1.domainEntry)
        }

        #expect(abs((workout.totalVolume ?? 0) - expectedWorkoutVolume) < 0.0001)
        #expect(abs(metrics.volume - expectedVisibleVolume) < 0.0001)
        #expect(abs(metrics.completedSets - expectedSets) < 0.0001)
    }
}
