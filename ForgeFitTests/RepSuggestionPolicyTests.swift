import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct RepSuggestionPolicyTests {
    private let userID = ForgeFitDemo.userID

    @Test func fixedLoadKeepsHistoricalRepPrecedence() {
        let set = SetModel(userID: userID, reps: 5)

        let suggestion = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 9,
            progressionLeads: false
        )

        #expect(suggestion.materializedValue == 9)
        #expect(suggestion.placeholder == "9")
        #expect(suggestion.quickAdjustmentBase == 9)
    }

    @Test func percentageExactTargetBeatsHistoricalReps() {
        let set = SetModel(
            userID: userID,
            reps: 5,
            prescribedLoadMode: .percentEstimatedOneRepMax,
            prescribedRepsLow: 5,
            prescribedRepsHigh: 5
        )

        let suggestion = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 9,
            progressionLeads: true
        )

        #expect(suggestion.materializedValue == 5)
        #expect(suggestion.placeholder == "5")
        #expect(suggestion.quickAdjustmentBase == 5)
        #expect(!set.requiresConcreteRepsBeforeCompletion)
    }

    @Test func percentageRangeIsGuidanceUntilAResultIsEntered() {
        let set = SetModel(
            userID: userID,
            prescribedLoadMode: .percentEstimatedOneRepMax,
            prescribedRepsLow: 5,
            prescribedRepsHigh: 8
        )

        let suggestion = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 9,
            progressionLeads: false
        )

        #expect(suggestion.materializedValue == nil)
        #expect(suggestion.placeholder == "5–8")
        #expect(suggestion.quickAdjustmentBase == 5)
        #expect(set.requiresConcreteRepsBeforeCompletion)

        set.reps = 9
        #expect(!set.requiresConcreteRepsBeforeCompletion)
    }

    @Test func missingPercentageTargetStaysBlankInsteadOfBorrowingHistory() {
        let set = SetModel(
            userID: userID,
            prescribedLoadMode: .percentEstimatedOneRepMax
        )

        let suggestion = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 9,
            progressionLeads: false
        )

        #expect(suggestion.materializedValue == nil)
        #expect(suggestion.placeholder == "—")
        #expect(suggestion.quickAdjustmentBase == nil)
        #expect(set.requiresConcreteRepsBeforeCompletion)
    }

    @Test func legacyPercentageSetWithoutRepSnapshotUsesStoredTargetNotHistory() {
        let set = SetModel(
            userID: userID,
            reps: 5,
            prescribedLoadMode: .percentEstimatedOneRepMax
        )

        let suggestion = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 9,
            progressionLeads: false
        )

        #expect(suggestion.materializedValue == 5)
        #expect(suggestion.placeholder == "5")
        #expect(suggestion.quickAdjustmentBase == 5)
        #expect(!set.requiresConcreteRepsBeforeCompletion)
    }

    @Test func percentageLoadDoesNotReplaceStructuredRepBehavior() {
        let set = SetModel(
            userID: userID,
            setType: .myoRep,
            prescribedLoadMode: .percentEstimatedOneRepMax,
            prescribedRepsLow: 5,
            prescribedRepsHigh: 8
        )

        let history = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 12,
            progressionLeads: false
        )
        let override = RepSuggestionPolicy.resolve(
            set: set,
            previousReps: 12,
            progressionLeads: false,
            structuredOverride: 10
        )

        #expect(history.materializedValue == 12)
        #expect(override.materializedValue == 10)
        #expect(!set.requiresConcreteRepsBeforeCompletion)
    }
}
