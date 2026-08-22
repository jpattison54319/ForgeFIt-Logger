import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

/// The two lengthened set types have to survive every surface that reads a
/// set, not just the logger row that creates them: history text, share text,
/// derived metrics, and the record ladder.
@MainActor
struct LengthenedSetTypeTests {

    private func makeSet(
        type: SetType,
        reps: Int?,
        partialReps: Int? = nil,
        weightKg: Double? = 100,
        completed: Bool = true
    ) -> SetModel {
        let set = SetModel(
            userID: UUID(),
            position: 0,
            setType: type,
            reps: reps,
            weight: weightKg,
            partialReps: partialReps
        )
        if completed { set.completedAt = Date() }
        set.recomputeDerivedMetrics()
        return set
    }

    // MARK: - Reading a set back

    @Test
    func historyReadsAPartialRangeSetAsPartials() {
        let set = makeSet(type: .lengthenedPartial, reps: 12)
        #expect(HistoricalSetPresentation.outputText(set) == "12 partials")
        #expect(HistoricalSetPresentation.shareValue(set, unit: .kg) == "100 kg × 12 partials")
    }

    @Test
    func historyKeepsAnExtendedSetsTwoHalvesApart() {
        let set = makeSet(type: .lengthenedExtended, reps: 8, partialReps: 4)
        #expect(HistoricalSetPresentation.outputText(set) == "8 + 4 partials")
        #expect(HistoricalSetPresentation.shareValue(set, unit: .kg) == "100 kg × 8 + 4 partials")
    }

    /// An extended set that never got its continuation reads as the plain set
    /// it turned out to be, not as "8 + 0 partials".
    @Test
    func anExtendedSetWithoutPartialsReadsAsAPlainSet() {
        let set = makeSet(type: .lengthenedExtended, reps: 8)
        #expect(HistoricalSetPresentation.outputText(set) == "8 reps")
        #expect(HistoricalSetPresentation.partialRangeReps(set) == nil)
    }

    @Test
    func anIncompleteSetStillReadsAsNotDone() {
        let set = makeSet(type: .lengthenedPartial, reps: 12, completed: false)
        #expect(HistoricalSetPresentation.outputText(set) == HistoricalSetPresentation.incompleteLabel)
    }

    // MARK: - Derived metrics

    @Test
    func derivedMetricsHalveAPartialRangeSetAndWithholdIts1RM() {
        let set = makeSet(type: .lengthenedPartial, reps: 10)
        #expect(set.totalVolume == 500)
        #expect(set.estimated1RM == nil)
    }

    @Test
    func derivedMetricsCountAnExtendedSetsPartialsAtHalf() throws {
        let set = makeSet(type: .lengthenedExtended, reps: 8, partialReps: 4)
        #expect(set.totalVolume == 1000)
        let oneRM = try #require(set.estimated1RM)
        #expect(abs(oneRM - 100 * (1 + 8.0 / 30.0)) < 0.0001)
    }

    // MARK: - Records

    /// A load moved through part of the range is not the same lift, so it
    /// never becomes the heaviest-weight bar — and never clears one.
    @Test
    func partialRangeSetsAreOutsideTheHeaviestWeightLadder() {
        var baseline = ExerciseRecordBaseline()
        baseline.absorb(makeSet(type: .working, reps: 5, weightKg: 90))
        #expect(baseline.maxLoad == 90)

        var partialOnly = ExerciseRecordBaseline()
        partialOnly.absorb(makeSet(type: .lengthenedPartial, reps: 10, weightKg: 120))
        #expect(partialOnly.maxLoad == 0)
        #expect(partialOnly.hasHistory == false)

        let heavyPartial = makeSet(type: .lengthenedPartial, reps: 10, weightKg: 120)
        let awards = PersonalRecords.awards(for: heavyPartial, baseline: baseline, sessionSets: [])
        #expect(!awards.contains(.heaviestWeight))
        #expect(!awards.contains(.best1RM))
    }

    /// The full-range half of an extended set is a real set, so it competes
    /// for records exactly like a working set does.
    @Test
    func extendedSetsStillCompeteForRecords() {
        var baseline = ExerciseRecordBaseline()
        baseline.absorb(makeSet(type: .working, reps: 5, weightKg: 90))

        let extended = makeSet(type: .lengthenedExtended, reps: 8, partialReps: 4, weightKg: 100)
        let awards = PersonalRecords.awards(for: extended, baseline: baseline, sessionSets: [])
        #expect(awards.contains(.heaviestWeight))
        #expect(awards.contains(.best1RM))
    }

    // MARK: - Round trip

    /// Partials ride the existing set field, so they have to survive the
    /// round trip every other logged number takes.
    @Test
    func partialsSurviveAStoreRoundTrip() throws {
        let (container, context) = try TestStore.make()
        _ = container
        let workout = WorkoutModel(userID: UUID(), startedAt: Date())
        let exercise = WorkoutExerciseModel(userID: workout.userID, exerciseID: UUID(), position: 0)
        let set = makeSet(type: .lengthenedExtended, reps: 8, partialReps: 4)
        context.insert(workout)
        context.insert(exercise)
        context.insert(set)
        exercise.sets = [set]
        workout.exercises = [exercise]
        try context.save()

        let fresh = ModelContext(container)
        let stored = try #require(try fresh.fetch(FetchDescriptor<SetModel>()).first)
        #expect(stored.setType == .lengthenedExtended)
        #expect(stored.reps == 8)
        #expect(stored.partialReps == 4)
        #expect(stored.totalVolume == 1000)
    }
}
