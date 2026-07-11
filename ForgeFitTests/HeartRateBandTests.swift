import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// `HeartRateTrendChart.cardioBands` — the shaded cardio windows behind a
/// hybrid session's HR trace. Bands must come only from live-tracked sessions
/// with trustworthy wall-clock windows (manual entries carry made-up times),
/// and never from pure-cardio workouts, where shading everything says nothing.
@MainActor
struct HeartRateBandTests {
    private static func makeContainer() throws -> (container: ModelContainer, context: ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private let userID = UUID()
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func run(linkedTo exercise: WorkoutExerciseModel) -> CardioSessionModel {
        let session = CardioSessionModel(userID: userID, modality: "run")
        session.workoutExerciseID = exercise.id
        return session
    }

    @Test func liveCardioInHybridWorkoutProducesBand() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let lift = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let session = run(linkedTo: runExercise)
        session.liveStartedAt = start.addingTimeInterval(1800)
        session.endedAt = start.addingTimeInterval(2400)
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        context.insert(workout)

        let bands = HeartRateTrendChart.cardioBands(for: workout)
        #expect(bands.count == 1)
        #expect(bands.first?.start == start.addingTimeInterval(1800))
        #expect(bands.first?.end == start.addingTimeInterval(2400))
    }

    @Test func manualCardioWithoutLiveWindowIsSkipped() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let lift = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let session = run(linkedTo: runExercise)
        session.durationSeconds = 600   // logged after the fact — no live window
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        context.insert(workout)

        #expect(HeartRateTrendChart.cardioBands(for: workout).isEmpty)
    }

    @Test func pureCardioWorkoutHasNoBands() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let session = run(linkedTo: runExercise)
        session.liveStartedAt = start
        session.endedAt = start.addingTimeInterval(1200)
        let workout = WorkoutModel(userID: userID, exercises: [runExercise], cardioSessions: [session])
        context.insert(workout)

        #expect(HeartRateTrendChart.cardioBands(for: workout).isEmpty)
    }

    @Test func openEndedSessionFallsBackToDuration() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let lift = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let session = run(linkedTo: runExercise)
        session.liveStartedAt = start.addingTimeInterval(1800)
        session.durationSeconds = 600
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        context.insert(workout)

        let bands = HeartRateTrendChart.cardioBands(for: workout)
        #expect(bands.first?.end == start.addingTimeInterval(2400))
    }
}
