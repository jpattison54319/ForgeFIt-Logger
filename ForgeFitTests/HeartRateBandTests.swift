import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// `HeartRateTrendChart.modalityBands` — the shaded timed-modality windows
/// behind a workout's HR trace. Bands must come only from live-tracked
/// sessions with trustworthy wall-clock windows (manual entries carry
/// made-up times), distinguish cardio/conditioning/yoga, and collapse the
/// summary + movement sessions owned by one block into one window.
@MainActor
struct HeartRateBandTests {
    private let userID = UUID()
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func run(linkedTo exercise: WorkoutExerciseModel) -> CardioSessionModel {
        let session = CardioSessionModel(userID: userID, modality: "run")
        session.workoutExerciseID = exercise.id
        return session
    }

    @Test func liveCardioInHybridWorkoutProducesBand() throws {
        let (container, context) = try TestStore.make()
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
        #expect(bands.first?.kind == .cardio)
    }

    @Test func manualCardioWithoutLiveWindowIsSkipped() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let lift = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let session = run(linkedTo: runExercise)
        session.durationSeconds = 600   // logged after the fact — no live window
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        context.insert(workout)

        #expect(HeartRateTrendChart.cardioBands(for: workout).isEmpty)
    }

    @Test func pureCardioWorkoutProducesCardioBand() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        let session = run(linkedTo: runExercise)
        session.liveStartedAt = start
        session.endedAt = start.addingTimeInterval(1200)
        let workout = WorkoutModel(userID: userID, exercises: [runExercise], cardioSessions: [session])
        context.insert(workout)

        let bands = HeartRateTrendChart.modalityBands(for: workout)
        #expect(bands.count == 1)
        #expect(bands.first?.kind == .cardio)
    }

    @Test func openEndedSessionFallsBackToDuration() throws {
        let (container, context) = try TestStore.make()
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

    @Test func conditioningAndYogaHaveDistinctBandKinds() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let conditioningBlock = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 0
        )
        let yogaBlock = WorkoutBlockModel(userID: userID, kind: .yoga, position: 1)
        let conditioning = CardioSessionModel(
            userID: userID,
            workoutBlockID: conditioningBlock.id,
            modality: CardioSessionModel.conditioningModality,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(600)
        )
        let yoga = CardioSessionModel(
            userID: userID,
            workoutBlockID: yogaBlock.id,
            modality: CardioSessionModel.yogaModality,
            liveStartedAt: start.addingTimeInterval(900),
            endedAt: start.addingTimeInterval(1_500)
        )
        let workout = WorkoutModel(
            userID: userID,
            cardioSessions: [conditioning, yoga],
            blocks: [conditioningBlock, yogaBlock]
        )
        context.insert(workout)

        let bands = HeartRateTrendChart.modalityBands(for: workout)
        #expect(bands.map(\.kind) == [.conditioning, .yoga])
    }

    @Test func sessionsOwnedByOneConditioningBlockCollapseToLongestWindow() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let block = WorkoutBlockModel(userID: userID, kind: .conditioning)
        let summary = CardioSessionModel(
            userID: userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(900)
        )
        let movement = CardioSessionModel(
            userID: userID,
            workoutBlockID: block.id,
            modality: "row",
            liveStartedAt: start.addingTimeInterval(120),
            endedAt: start.addingTimeInterval(420)
        )
        let workout = WorkoutModel(
            userID: userID,
            cardioSessions: [movement, summary],
            blocks: [block]
        )
        context.insert(workout)

        let bands = HeartRateTrendChart.modalityBands(for: workout)
        #expect(bands.count == 1)
        #expect(bands.first?.id == summary.id)
        #expect(bands.first?.kind == .conditioning)
    }
}
