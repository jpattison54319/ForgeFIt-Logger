import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct XPServiceTests {
    private let userID = ForgeFitDemo.userID

    @Test func strengthWorkoutXPUsesBaseDurationAndWorkingSets() {
        let workout = strengthWorkout(minutes: 60, completedSets: 5)

        let award = XPService.previewAward(for: workout)

        #expect(award.eligible)
        #expect(award.amount == 140)
        #expect(award.base == 50)
        #expect(award.duration == 60)
        #expect(award.strength == 30)
    }

    @Test func cardioWorkoutXPUsesDurationAndDistance() {
        let workout = cardioWorkout(minutes: 30, distanceMeters: 5_000)

        let award = XPService.previewAward(for: workout)

        #expect(award.eligible)
        #expect(award.amount == 136)
        #expect(award.cardioDuration == 36)
        #expect(award.cardioDistance == 20)
    }

    @Test func highVolumeWorkoutXPIsCapped() {
        let workout = strengthWorkout(minutes: 180, completedSets: 30)
        workout.cardioSessions = [
            CardioSessionModel(
                userID: userID,
                modality: CardioKind.run.rawValue,
                startedAt: workout.startedAt,
                endedAt: workout.endedAt,
                durationSeconds: 7_200,
                distanceMeters: 100_000
            )
        ]

        let award = XPService.previewAward(for: workout)

        #expect(award.amount == XPService.perWorkoutCap)
    }

    @Test func shortInvalidWorkoutGetsNoXP() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let workout = WorkoutModel(
            userID: userID,
            startedAt: now,
            endedAt: now.addingTimeInterval(240),
            sourceDevice: "iphone"
        )

        let award = XPService.previewAward(for: workout)

        #expect(!award.eligible)
        #expect(award.amount == 0)
    }

    @Test func levelCurveStartsSlowAndScales() {
        #expect(XPService.requiredTotalXP(forLevel: 1) == 0)
        #expect(XPService.requiredTotalXP(forLevel: 2) == 300)
        #expect(XPService.level(forTotalXP: 299) == 1)
        #expect(XPService.level(forTotalXP: 300) == 2)
        #expect((11_200...11_400).contains(XPService.requiredTotalXP(forLevel: 10)))
        #expect((38_000...40_000).contains(XPService.requiredTotalXP(forLevel: 20)))
    }

    @Test func awardingIsIdempotent() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = strengthWorkout(minutes: 45, completedSets: 4)
        context.insert(workout)
        try context.save()

        let first = XPService.awardXPIfNeeded(for: workout, in: context)
        let second = XPService.awardXPIfNeeded(for: workout, in: context)

        #expect(first.amount == 119)
        #expect(second.amount == 119)
        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).count == 1)
        let progress = try #require(context.fetch(FetchDescriptor<UserProgressModel>()).first)
        #expect(progress.totalXP == 119)
    }

    @Test func importedHistoryDoesNotAwardXP() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = strengthWorkout(minutes: 45, completedSets: 4)
        workout.externalSource = "hevy"
        context.insert(workout)
        try context.save()

        let award = XPService.awardXPIfNeeded(for: workout, in: context)

        #expect(!award.eligible)
        #expect(award.amount == 0)
        #expect(try context.fetch(FetchDescriptor<WorkoutXPEventModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<UserProgressModel>()).isEmpty)
    }

    private func strengthWorkout(minutes: Int, completedSets: Int) -> WorkoutModel {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            sourceDevice: "iphone"
        )
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        exercise.sets = (0..<completedSets).map { index in
            SetModel(
                userID: userID,
                position: index,
                setType: .working,
                reps: 10,
                weight: 100,
                completedAt: start.addingTimeInterval(TimeInterval(index * 60))
            )
        }
        workout.exercises = [exercise]
        return workout
    }

    private func cardioWorkout(minutes: Int, distanceMeters: Double) -> WorkoutModel {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let workout = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
            sourceDevice: "iphone"
        )
        workout.cardioSessions = [
            CardioSessionModel(
                userID: userID,
                modality: CardioKind.run.rawValue,
                startedAt: start,
                endedAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                durationSeconds: minutes * 60,
                distanceMeters: distanceMeters
            )
        ]
        return workout
    }
}
