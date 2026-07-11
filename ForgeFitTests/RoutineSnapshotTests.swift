import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct RoutineSnapshotTests {
    private let userID = ForgeFitDemo.userID

    private func inMemoryContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func routine(in context: ModelContext) -> RoutineModel {
        let set = RoutineSetModel(userID: userID, position: 0, targetRepsLow: 8, targetRepsHigh: 12, targetWeight: 100)
        let exercise = RoutineExerciseModel(userID: userID, exerciseID: UUID(), position: 0, sets: [set])
        let routine = RoutineModel(userID: userID, name: "Upper A", notes: "original", exercises: [exercise])
        context.insert(routine)
        try? context.save()
        return routine
    }

    @Test func unchangedRoutineComparesEqual() throws {
        let context = ModelContext(try inMemoryContainer())
        let r = routine(in: context)
        let snapshot = RoutineSnapshot(of: r)
        #expect(snapshot == RoutineSnapshot(of: r))
    }

    @Test func editsMakeSnapshotsUnequal() throws {
        let context = ModelContext(try inMemoryContainer())
        let r = routine(in: context)
        let snapshot = RoutineSnapshot(of: r)
        r.name = "Upper B"
        #expect(snapshot != RoutineSnapshot(of: r))
    }

    @Test func restoreUndoesRenameRemovalAndAddition() throws {
        let context = ModelContext(try inMemoryContainer())
        let r = routine(in: context)
        let originalExerciseID = r.exercises[0].id
        let snapshot = RoutineSnapshot(of: r)

        // The reported flow: rename, remove the exercise, add a new one.
        r.name = "Renamed"
        r.notes = nil
        let removed = r.exercises[0]
        r.exercises.removeAll { $0.id == removed.id }
        context.delete(removed)
        let added = RoutineExerciseModel(userID: userID, exerciseID: UUID(), position: 0,
                                         sets: [RoutineSetModel(userID: userID, targetRepsLow: 5)])
        context.insert(added)
        r.exercises.append(added)
        try context.save()

        snapshot.restore(onto: r, in: context)

        #expect(r.name == "Upper A")
        #expect(r.notes == "original")
        #expect(r.exercises.count == 1)
        #expect(r.exercises[0].id == originalExerciseID)   // identity preserved
        let sets = r.exercises[0].sets
        #expect(sets.count == 1)
        #expect(sets[0].targetWeight == 100)
        #expect(sets[0].targetRepsLow == 8)
        // The added exercise is really gone from the store.
        let allExercises = try context.fetch(FetchDescriptor<RoutineExerciseModel>())
        #expect(allExercises.count == 1)
        #expect(RoutineSnapshot(of: r) == snapshot)
    }

    @Test func restoreUndoesSetTargetEdits() throws {
        let context = ModelContext(try inMemoryContainer())
        let r = routine(in: context)
        let snapshot = RoutineSnapshot(of: r)

        r.exercises[0].sets[0].targetWeight = 140
        r.exercises[0].sets[0].targetRepsLow = 3
        try context.save()
        #expect(snapshot != RoutineSnapshot(of: r))

        snapshot.restore(onto: r, in: context)
        #expect(r.exercises[0].sets[0].targetWeight == 100)
        #expect(r.exercises[0].sets[0].targetRepsLow == 8)
    }

    /// The flow builder saves eagerly, so `yogaFlowJSON` MUST live in the
    /// snapshot: leaving it out made flow-only edits skip the discard prompt
    /// entirely AND made "Discard Changes" keep the edited flow.
    @Test func flowOnlyEditsAreDetectedAndRestored() throws {
        let context = ModelContext(try inMemoryContainer())
        let r = routine(in: context)
        let original = #"{"poses":[{"name":"Balasana","holdSeconds":30}]}"#
        r.exercises[0].yogaFlowJSON = original
        try context.save()
        let snapshot = RoutineSnapshot(of: r)

        // A flow-only edit must make the snapshots unequal (discard prompt).
        r.exercises[0].yogaFlowJSON = #"{"poses":[{"name":"Savasana","holdSeconds":120}]}"#
        try context.save()
        #expect(snapshot != RoutineSnapshot(of: r))

        // And restoring must put the original flow back.
        snapshot.restore(onto: r, in: context)
        #expect(r.exercises[0].yogaFlowJSON == original)
        #expect(RoutineSnapshot(of: r) == snapshot)
    }

    @Test func restoreClearsFlowAddedSinceSnapshot() throws {
        let context = ModelContext(try inMemoryContainer())
        let r = routine(in: context)
        let snapshot = RoutineSnapshot(of: r)   // captured with no flow

        r.exercises[0].yogaFlowJSON = #"{"poses":[{"name":"Balasana","holdSeconds":30}]}"#
        try context.save()

        snapshot.restore(onto: r, in: context)
        #expect(r.exercises[0].yogaFlowJSON == nil)
    }
}

/// Assisted / added bodyweight modes: the weight column routes into the field
/// the volume math actually reads.
struct ModeWeightTests {
    private let userID = ForgeFitDemo.userID

    @Test func assistedModeRoutesToAssistanceAndSubtractsFromBodyweight() {
        let set = SetModel(userID: userID, setType: .working, weightMode: .bodyweightAssisted, reps: 10, bodyweightKg: 80)
        set.setModeWeight(20)   // 20 kg of assistance

        #expect(set.assistanceWeight == 20)
        #expect(set.weight == nil)          // not misrouted
        #expect(set.modeWeight == 20)
        #expect(set.effectiveLoad == 60)    // 80 bodyweight − 20 assistance
        #expect(set.totalVolume == 600)     // 60 × 10
    }

    @Test func addedModeRoutesToAddedWeight() {
        let set = SetModel(userID: userID, setType: .working, weightMode: .bodyweightAdded, reps: 5, bodyweightKg: 80)
        set.setModeWeight(25)

        #expect(set.addedWeight == 25)
        #expect(set.effectiveLoad == 105)   // 80 + 25
    }

    @Test func externalModeStillUsesWeight() {
        let set = SetModel(userID: userID, setType: .working, weightMode: .external, reps: 8)
        set.setModeWeight(100)
        #expect(set.weight == 100)
        #expect(set.effectiveLoad == 100)
    }
}
