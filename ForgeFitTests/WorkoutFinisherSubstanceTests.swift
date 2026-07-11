import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// The empty-workout guard: finishing a workout where nothing happened must
/// discard it (tombstone), never save it to history, award XP, or write a
/// phantom HKWorkout to Apple Health. `hasSubstance` defines "nothing
/// happened" — and typed notes count as something, because silently deleting
/// user text is worse than an odd history entry.
@MainActor
struct WorkoutFinisherSubstanceTests {
    private static func makeContainer() throws -> (container: ModelContainer, context: ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private let userID = UUID()

    @Test func emptyAndUntouchedWorkoutsHaveNoSubstance() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }

        let empty = WorkoutModel(userID: userID)
        context.insert(empty)
        #expect(!WorkoutFinisher.hasSubstance(empty))

        // Planned but untouched: incomplete sets and a cardio block that was
        // never started count for nothing.
        let incompleteSets = (0..<3).map { SetModel(userID: userID, position: $0, reps: 8, weight: 100) }
        let lift = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: incompleteSets)
        let plannedRun = CardioSessionModel(userID: userID, modality: "run")
        let untouched = WorkoutModel(userID: userID, exercises: [lift], cardioSessions: [plannedRun])
        context.insert(untouched)
        #expect(!WorkoutFinisher.hasSubstance(untouched))
    }

    @Test func completedSetLiveCardioManualYogaAndNotesAllCount() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }

        let done = SetModel(userID: userID, position: 0, reps: 8, weight: 100, completedAt: .now)
        let withSet = WorkoutModel(userID: userID, exercises: [WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: [done])])
        context.insert(withSet)
        #expect(WorkoutFinisher.hasSubstance(withSet))

        let liveRun = CardioSessionModel(userID: userID, modality: "run")
        liveRun.liveStartedAt = .now
        let withLiveCardio = WorkoutModel(userID: userID, cardioSessions: [liveRun])
        context.insert(withLiveCardio)
        #expect(WorkoutFinisher.hasSubstance(withLiveCardio))

        let manualYoga = CardioSessionModel(userID: userID, modality: "yoga")
        manualYoga.sourceDevice = CardioSessionModel.yogaManualSource
        let withYoga = WorkoutModel(userID: userID, cardioSessions: [manualYoga])
        context.insert(withYoga)
        #expect(WorkoutFinisher.hasSubstance(withYoga))

        let noted = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        noted.notes = "Left knee felt off on warm-ups"
        let withNotes = WorkoutModel(userID: userID, exercises: [noted])
        context.insert(withNotes)
        #expect(WorkoutFinisher.hasSubstance(withNotes))
    }

    /// The behavioral guarantee: finish() on an empty workout tombstones it
    /// instead of completing it — deletedAt set, endedAt never stamped.
    @Test func finishingAnEmptyWorkoutDiscardsInsteadOfSaving() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let workout = WorkoutModel(userID: userID)
        context.insert(workout)
        try context.save()

        let failure = WorkoutFinisher.finish(workout, in: context)

        #expect(failure == nil)
        #expect(workout.deletedAt != nil)
        #expect(workout.endedAt == nil)
    }
}
