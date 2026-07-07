import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct CoachAdjustmentsTests {
    private let userID = ForgeFitDemo.userID

    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Workout with one exercise: 1 warmup + 4 working sets at 100, RPE 9.
    private func workout(in context: ModelContext) -> WorkoutModel {
        let sets = [SetModel(userID: userID, position: 0, setType: .warmup, reps: 10, weight: 50)]
            + (1...4).map { SetModel(userID: userID, position: $0, reps: 8, weight: 100, rpe: 9) }
        let exercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID(), sets: sets)
        let w = WorkoutModel(userID: userID, exercises: [exercise])
        context.insert(w)
        try? context.save()
        return w
    }

    @Test func noPlanForGreenDays() {
        #expect(CoachAdjustments.plan(for: .push) == nil)
        #expect(CoachAdjustments.plan(for: .trainAsPlanned) == nil)
        #expect(CoachAdjustments.plan(for: .reduceVolume) != nil)
        #expect(CoachAdjustments.plan(for: .deloadRecover) != nil)
    }

    @Test func reduceVolumeDropsOneSetAndCapsRPE() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let w = workout(in: context)
        let plan = CoachAdjustments.plan(for: .reduceVolume)!

        CoachAdjustments.apply(plan, to: w, in: context)

        let sets = w.exercises[0].sets.sorted { $0.position < $1.position }
        #expect(sets.filter { $0.setType == .working }.count == 3)   // 4 → 3
        #expect(sets.contains { $0.setType == .warmup })             // warmup preserved
        #expect(sets.filter { $0.setType == .working }.allSatisfy { ($0.rpe ?? 0) <= 8 })
        #expect(sets.filter { $0.setType == .working }.allSatisfy { $0.weight == 100 })  // load untouched
        #expect(w.notes?.contains("Coach-adjusted") == true)
    }

    @Test func deloadHalvesSetsAndTrimsLoad() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let w = workout(in: context)
        let plan = CoachAdjustments.plan(for: .deloadRecover)!

        CoachAdjustments.apply(plan, to: w, in: context)

        let working = w.exercises[0].sets.filter { $0.setType == .working }
        #expect(working.count == 2)                                  // 4 → 2
        #expect(working.allSatisfy { $0.weight == 90 })              // −10%
        #expect(working.allSatisfy { ($0.rpe ?? 0) <= 7 })
        // Removed sets are actually deleted, not orphaned.
        let all = try context.fetch(FetchDescriptor<SetModel>())
        #expect(all.filter { $0.setType == .working }.count == 2)
    }

    @Test func smallExercisesKeepMinimumOneWorkingSet() throws {
        let container = try inMemoryContainer()
        let context = ModelContext(container)
        let exercise = WorkoutExerciseModel(
            userID: userID, exerciseID: UUID(),
            sets: [SetModel(userID: userID, position: 0, reps: 8, weight: 60, rpe: 8)]
        )
        let w = WorkoutModel(userID: userID, exercises: [exercise])
        context.insert(w)
        try context.save()

        CoachAdjustments.apply(CoachAdjustments.plan(for: .deloadRecover)!, to: w, in: context)
        #expect(w.exercises[0].sets.count == 1)

        // reduceVolume never cuts a 2-set exercise below 2.
        let context2 = ModelContext(try inMemoryContainer())
        let two = WorkoutExerciseModel(
            userID: userID, exerciseID: UUID(),
            sets: (0..<2).map { SetModel(userID: userID, position: $0, reps: 8, weight: 60, rpe: 9) }
        )
        let w2 = WorkoutModel(userID: userID, exercises: [two])
        context2.insert(w2)
        try context2.save()
        CoachAdjustments.apply(CoachAdjustments.plan(for: .reduceVolume)!, to: w2, in: context2)
        #expect(w2.exercises[0].sets.count == 2)
    }
}
