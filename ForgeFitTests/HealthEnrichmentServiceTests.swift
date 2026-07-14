import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// Canned Apple Health responses for enrichment tests.
private struct MockHealth: HealthEnriching {
    var snapshot = CardioSnapshot(durationSeconds: 1800, avgHR: 152, maxHR: 178, activeEnergyKcal: 410, distanceMeters: nil)
    var bodyMass: Double? = 81.5
    var matchedUUID: UUID? = UUID()

    func importSnapshot(from start: Date, to end: Date, modality: CardioKind) async -> CardioSnapshot { snapshot }
    func bodyMassKg(near date: Date, toleranceDays: Int) async -> Double? { bodyMass }
    func workoutUUID(matchingStart start: Date, end: Date, tolerance: TimeInterval) async -> UUID? { matchedUUID }
}

@MainActor
struct HealthEnrichmentServiceTests {

    private func restoredWorkout(userID: UUID, in context: ModelContext) -> WorkoutModel {
        let workout = WorkoutModel(userID: userID, title: "Restored", startedAt: Date(timeIntervalSinceNow: -7200))
        workout.endedAt = workout.startedAt.addingTimeInterval(3600)
        context.insert(workout)
        return workout
    }

    @Test func fillsNilHealthFieldsAndRelinksUUID() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let userID = ForgeFitDemo.userID
        let workout = restoredWorkout(userID: userID, in: context)
        try context.save()

        let mock = MockHealth()
        let summary = await HealthEnrichmentService(health: mock).enrich(workoutIDs: [workout.id], in: context)

        #expect(workout.avgHR == 152)
        #expect(workout.maxHR == 178)
        #expect(workout.activeEnergyKcal == 410)
        #expect(!workout.hrZoneSeconds.isEmpty)
        #expect(workout.hkWorkoutUUID == mock.matchedUUID)
        #expect(summary.workoutsEnriched == 1)
        #expect(summary.healthUUIDsRelinked == 1)
    }

    @Test func neverOverwritesExistingValues() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let userID = ForgeFitDemo.userID
        let workout = restoredWorkout(userID: userID, in: context)
        workout.avgHR = 140
        workout.maxHR = 165
        workout.activeEnergyKcal = 300
        workout.hkWorkoutUUID = UUID()
        let originalUUID = workout.hkWorkoutUUID
        try context.save()

        _ = await HealthEnrichmentService(health: MockHealth()).enrich(workoutIDs: [workout.id], in: context)

        #expect(workout.avgHR == 140)
        #expect(workout.maxHR == 165)
        #expect(workout.activeEnergyKcal == 300)
        #expect(workout.hkWorkoutUUID == originalUUID)
    }

    @Test func skipsSoftDeletedWorkouts() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let userID = ForgeFitDemo.userID
        let workout = restoredWorkout(userID: userID, in: context)
        workout.deletedAt = Date()
        try context.save()

        let summary = await HealthEnrichmentService(health: MockHealth()).enrich(workoutIDs: [workout.id], in: context)

        #expect(workout.avgHR == nil)
        #expect(summary.workoutsEnriched == 0)
    }

    @Test func refillsBodyweightAndRecomputesVolume() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let userID = ForgeFitDemo.userID
        let workout = restoredWorkout(userID: userID, in: context)
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        context.insert(exercise)
        workout.exercises.append(exercise)
        let set = SetModel(userID: userID, position: 0)
        set.weightModeRaw = WeightMode.bodyweight.rawValue
        set.reps = 10
        set.completedAt = workout.startedAt.addingTimeInterval(600)
        context.insert(set)
        exercise.sets.append(set)
        try context.save()
        #expect(set.bodyweightKg == nil)

        let summary = await HealthEnrichmentService(health: MockHealth()).enrich(workoutIDs: [workout.id], in: context)

        #expect(set.bodyweightKg == 81.5)
        #expect(summary.setsBodyweightFilled == 1)
        #expect((set.totalVolume ?? 0) > 0)
    }

    @Test func enrichesOnlyRequestedWorkouts() async throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let userID = ForgeFitDemo.userID
        let target = restoredWorkout(userID: userID, in: context)
        let bystander = restoredWorkout(userID: userID, in: context)
        try context.save()

        _ = await HealthEnrichmentService(health: MockHealth()).enrich(workoutIDs: [target.id], in: context)

        #expect(target.avgHR == 152)
        #expect(bystander.avgHR == nil)
    }
}
