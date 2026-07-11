import ForgeData
import Foundation
import SwiftData
import Testing
import UIKit
@testable import ForgeFit

/// The share carousel's shape detection, page availability, and the
/// training-log card's layout budget. These rules keep the four workout
/// shapes consistent across every card style — a drift here shows up as a
/// hollow or overflowing share image.
@MainActor
struct ShareCardStyleTests {
    private static func makeContainer() throws -> (container: ModelContainer, context: ModelContext) {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return (container, container.mainContext)
    }

    private let userID = UUID()

    private func strengthExercise(sets: Int = 3, weight: Double = 100) -> WorkoutExerciseModel {
        let setModels = (0..<sets).map {
            SetModel(userID: userID, position: $0, reps: 8, weight: weight + Double($0), completedAt: .now)
        }
        return WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: setModels)
    }

    private func cardioSession(yoga: Bool = false, linkedTo exercise: WorkoutExerciseModel? = nil) -> CardioSessionModel {
        let session = CardioSessionModel(userID: userID, modality: yoga ? "yoga" : "run")
        session.workoutExerciseID = exercise?.id
        session.durationSeconds = 600
        return session
    }

    private func shape(of workout: WorkoutModel) -> WorkoutShareShape {
        let summary = TrainingAnalytics(workouts: [workout], exercises: []).summary(for: workout)
        return .of(workout: workout, summary: summary)
    }

    // MARK: - Shape detection

    @Test func shapesResolveForAllFourWorkoutKinds() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }

        let strength = WorkoutModel(userID: userID, exercises: [strengthExercise()])
        context.insert(strength)
        #expect(shape(of: strength) == .strength)

        let cardio = WorkoutModel(userID: userID, cardioSessions: [cardioSession()])
        context.insert(cardio)
        #expect(shape(of: cardio) == .cardio)

        let yoga = WorkoutModel(userID: userID, cardioSessions: [cardioSession(yoga: true)])
        context.insert(yoga)
        #expect(shape(of: yoga) == .yoga)

        let hybrid = WorkoutModel(userID: userID, exercises: [strengthExercise()], cardioSessions: [cardioSession()])
        context.insert(hybrid)
        #expect(shape(of: hybrid) == .hybrid)
    }

    // MARK: - Page availability

    @Test func metricsPageOnlyExistsWithHeartRateData() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let workout = WorkoutModel(userID: userID, exercises: [strengthExercise()])
        context.insert(workout)
        let summary = TrainingAnalytics(workouts: [workout], exercises: []).summary(for: workout)

        let without = ShareCardStyle.available(workout: workout, summary: summary, hasHRSamples: false)
        #expect(!without.contains(.metrics))
        #expect(without == [.trainingLog, .minimal, .full])

        workout.hrZoneSeconds = [600, 300, 0, 0, 0]
        let withZones = ShareCardStyle.available(workout: workout, summary: summary, hasHRSamples: false)
        #expect(withZones.contains(.metrics))
    }

    // MARK: - Training-log budget

    @Test func smallSessionShowsEverySet() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let workout = WorkoutModel(userID: userID, exercises: [strengthExercise(sets: 3), strengthExercise(sets: 4)])
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 14)
        let blocks = plan.entries.compactMap { entry -> ShareTrainingLogPlan.StrengthBlock? in
            if case .strength(let block) = entry { return block }
            return nil
        }
        #expect(blocks.count == 2)
        #expect(blocks.map(\.lines.count) == [3, 4])
        #expect(blocks.allSatisfy { $0.extraSets == 0 })
        #expect(plan.moreExercises == 0)
    }

    @Test func largeSessionCollapsesToTopSets() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        // 4 exercises × 6 sets = 24 completed sets — over any budget.
        let workout = WorkoutModel(userID: userID, exercises: (0..<4).map { _ in strengthExercise(sets: 6) })
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 14)
        let blocks = plan.entries.compactMap { entry -> ShareTrainingLogPlan.StrengthBlock? in
            if case .strength(let block) = entry { return block }
            return nil
        }
        #expect(blocks.allSatisfy { $0.lines.count == 1 })
        #expect(blocks.allSatisfy { $0.extraSets == 5 })
    }

    @Test func exercisesBeyondCapBecomeMoreCount() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let workout = WorkoutModel(userID: userID, exercises: (0..<8).map { _ in strengthExercise(sets: 2) })
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 14)
        let strengthEntries = plan.entries.filter { if case .strength = $0 { return true } else { return false } }
        #expect(strengthEntries.count == ShareTrainingLogPlan.maxExercises)
        #expect(plan.moreExercises == 2)
    }

    // MARK: - Render smoke test

    /// Rasterizes every card style for a hybrid workout with HR data — the
    /// worst-case layout (charts, zone bar, splits, GeometryReader bars all
    /// live). Catches render-time layout crashes the type checker can't.
    @Test func allCardStylesRenderToCorrectlySizedImages() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let lift = strengthExercise(sets: 4)
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        runExercise.position = 1
        let session = cardioSession(linkedTo: runExercise)
        session.liveStartedAt = Date(timeIntervalSince1970: 1_780_000_000)
        session.endedAt = Date(timeIntervalSince1970: 1_780_000_600)
        session.distanceMeters = 2000
        session.avgHR = 150
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        workout.endedAt = workout.startedAt.addingTimeInterval(2700)
        workout.hrZoneSeconds = [1000, 300, 200, 100, 0]
        workout.avgHR = 131
        workout.maxHR = 175
        workout.activeEnergyKcal = 400
        context.insert(workout)

        let theme = AppTheme.sageDark
        let samples = (0..<60).map { (date: workout.startedAt.addingTimeInterval(Double($0) * 45), bpm: 110 + ($0 % 40)) }

        let trainingLog = ShareRenderer.image(
            WorkoutShareCardTrainingLog(workout: workout, exercises: [], theme: theme), theme: theme
        )
        #expect(trainingLog?.size == WorkoutShareCardTrainingLog.size)

        let metrics = ShareRenderer.image(
            WorkoutShareCardMetrics(workout: workout, exercises: [], theme: theme, hrSamples: samples), theme: theme
        )
        #expect(metrics?.size == WorkoutShareCardMetrics.size)

        let minimal = ShareRenderer.image(
            WorkoutShareCardMinimal(workout: workout, exercises: [], theme: theme), theme: theme
        )
        #expect(minimal?.size == WorkoutShareCardMinimal.size)

        let full = WorkoutShareRenderer.image(for: workout, exercises: [], theme: theme, hrSamples: samples)
        #expect(full != nil)
        #expect(full?.size.width == 430)
    }

    @Test func hybridPlanKeepsCardioInPosition() throws {
        let (container, context) = try Self.makeContainer()
        defer { _ = container }
        let lift = strengthExercise(sets: 3)
        lift.position = 0
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        runExercise.position = 1
        let session = cardioSession(linkedTo: runExercise)
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 12)
        #expect(plan.entries.count == 2)
        if case .cardio(let cardioEntry) = plan.entries[1] {
            #expect(cardioEntry.id == session.id)
        } else {
            Issue.record("expected the cardio session as the second entry")
        }
    }
}
