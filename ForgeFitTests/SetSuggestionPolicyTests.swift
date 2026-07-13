import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

/// The commit-on-complete rule for placeholder-style suggested values: what
/// the placeholders DISPLAYED is exactly what completing commits — typed
/// fields win, untouched fields take the suggestion, empty-with-no-history
/// stays empty, and a completed set is never rewritten.
struct SetSuggestionPolicyTests {
    private let userID = ForgeFitDemo.userID

    private func previousSet(weight: Double? = 84, reps: Int? = 8, rpe: Double? = 7.5, rir: Int? = nil) -> SetModel {
        SetModel(userID: userID, reps: reps, weight: weight, rpe: rpe, rir: rir, completedAt: Date(timeIntervalSince1970: 1_799_000_000))
    }

    /// Requirement 3: complete with nothing typed → every placeholder
    /// becomes the real value.
    @Test func untouchedSuggestionCommitsAllPlaceholders() {
        let set = SetModel(userID: userID, weight: 80)   // routine-seeded target
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(), suggestionBacked: true, editedFields: [])
        #expect(set.weight == 84)   // previous session wins over the seed target
        #expect(set.reps == 8)
        #expect(set.rpe == 7.5)
    }

    /// Requirement 5: typed weight + untouched reps → typed weight survives,
    /// reps takes the placeholder.
    @Test func editedFieldWinsUntouchedFieldTakesPlaceholder() {
        let set = SetModel(userID: userID, weight: 90)   // user typed 90
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(), suggestionBacked: true, editedFields: [.weight])
        #expect(set.weight == 90)
        #expect(set.reps == 8)
    }

    /// Completion receives the exact values displayed as ghosts. Each field
    /// resolves independently, so typing either side cannot strand the other
    /// side as a placeholder.
    @Test func displayedWeightAndRepsMaterializeIndependently() {
        let suggestions = SetSuggestionPolicy.SuggestedValues(weight: 84, reps: 8)

        let onlyWeightTyped = SetModel(userID: userID, weight: 90)
        SetSuggestionPolicy.materialize(
            set: onlyWeightTyped,
            suggestions: suggestions,
            suggestionBacked: true,
            editedFields: [.weight]
        )
        #expect(onlyWeightTyped.weight == 90)
        #expect(onlyWeightTyped.reps == 8)

        let onlyRepsTyped = SetModel(userID: userID, reps: 12)
        SetSuggestionPolicy.materialize(
            set: onlyRepsTyped,
            suggestions: suggestions,
            suggestionBacked: true,
            editedFields: [.primary]
        )
        #expect(onlyRepsTyped.weight == 84)
        #expect(onlyRepsTyped.reps == 12)

        let nothingTyped = SetModel(userID: userID)
        SetSuggestionPolicy.materialize(
            set: nothingTyped,
            suggestions: suggestions,
            suggestionBacked: true,
            editedFields: []
        )
        #expect(nothingTyped.weight == 84)
        #expect(nothingTyped.reps == 8)
    }

    /// Added/assisted bodyweight fields display their mode-specific load, not
    /// `SetModel.weight`; completion must write back to that same field.
    @Test func displayedWeightUsesTheSetsWeightMode() {
        let added = SetModel(userID: userID, weightMode: .bodyweightAdded)
        SetSuggestionPolicy.materialize(
            set: added,
            suggestions: .init(weight: 20, reps: 10),
            suggestionBacked: true,
            editedFields: []
        )
        #expect(added.addedWeight == 20)
        #expect(added.weight == nil)
        #expect(added.reps == 10)

        let assisted = SetModel(userID: userID, weightMode: .bodyweightAssisted)
        SetSuggestionPolicy.materialize(
            set: assisted,
            suggestions: .init(weight: 35, reps: 6),
            suggestionBacked: true,
            editedFields: []
        )
        #expect(assisted.assistanceWeight == 35)
        #expect(assisted.weight == nil)
        #expect(assisted.reps == 6)
    }

    /// Watch mirroring marks the model complete before the phone row observes
    /// it. The reconciliation path may materialize that just-completed set,
    /// while the default policy still protects established history.
    @Test func externalCompletionCanMaterializeDisplayedGhosts() {
        let set = SetModel(userID: userID, completedAt: Date())
        SetSuggestionPolicy.materialize(
            set: set,
            suggestions: .init(weight: 84, reps: 8),
            suggestionBacked: true,
            editedFields: [],
            allowsCompletedSet: true
        )
        #expect(set.weight == 84)
        #expect(set.reps == 8)
    }

    /// A field the user typed into and then cleared is un-marked by the
    /// caller — it returns to suggestion state and commits the placeholder.
    @Test func clearedFieldReturnsToSuggestionState() {
        let set = SetModel(userID: userID)   // weight cleared back to nil, field un-marked
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(), suggestionBacked: true, editedFields: [])
        #expect(set.weight == 84)
    }

    /// A menu-picked RPE is never overwritten by the suggestion.
    @Test func pickedRPESurvivesMaterialization() {
        let set = SetModel(userID: userID, rpe: 9)
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(rpe: 7, rir: 3), suggestionBacked: true, editedFields: [])
        #expect(set.rpe == 9)
        #expect(set.rir == nil)
    }

    /// Requirement 6 + seeded targets: no previous session → the placeholders
    /// showed the set's own seeded targets (or nothing); nothing changes.
    @Test func noPreviousSessionLeavesSeedValues() {
        let seeded = SetModel(userID: userID, reps: 10, weight: 82.5)
        SetSuggestionPolicy.materialize(set: seeded, previous: nil, suggestionBacked: true, editedFields: [])
        #expect(seeded.weight == 82.5)
        #expect(seeded.reps == 10)

        let empty = SetModel(userID: userID)
        SetSuggestionPolicy.materialize(set: empty, previous: nil, suggestionBacked: false, editedFields: [])
        #expect(empty.weight == nil)
        #expect(empty.reps == nil)
    }

    /// Ad-hoc sets (not routine-seeded): non-nil stored values are real
    /// entries and stay; only nil fields take their displayed placeholder —
    /// and RPE never auto-fills (its chip shows no suggestion on these rows).
    @Test func adHocSetFillsOnlyEmptyFields() {
        let set = SetModel(userID: userID, reps: 12)   // user entered reps; weight empty
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(), suggestionBacked: false, editedFields: [])
        #expect(set.weight == 84)
        #expect(set.reps == 12)
        #expect(set.rpe == nil)
    }

    /// A set that's already completed is never rewritten (re-completing after
    /// an uncheck must preserve the committed values — requirement 4).
    @Test func completedSetIsNeverRewritten() {
        let set = SetModel(userID: userID, reps: 8, weight: 84, completedAt: Date())
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(weight: 100, reps: 5), suggestionBacked: true, editedFields: [])
        #expect(set.weight == 84)
        #expect(set.reps == 8)
    }

    /// Cardio sets: the primary field is duration; same untouched/typed rules.
    @Test func cardioDurationFollowsTheSameRules() {
        let previous = SetModel(userID: userID, durationSeconds: 1_200, completedAt: Date(timeIntervalSince1970: 1_799_000_000))

        let untouched = SetModel(userID: userID)
        SetSuggestionPolicy.materialize(set: untouched, previous: previous, suggestionBacked: true, editedFields: [])
        #expect(untouched.durationSeconds == 1_200)

        let typed = SetModel(userID: userID, durationSeconds: 900)
        SetSuggestionPolicy.materialize(set: typed, previous: previous, suggestionBacked: true, editedFields: [.primary])
        #expect(typed.durationSeconds == 900)
    }

    /// Turning the effort column off is a logging decision, not just a visual
    /// one. Neither a prior-session suggestion nor an already-seeded value may
    /// survive completion while effort is hidden.
    @Test func hiddenEffortClearsSeedAndDoesNotCopyPrevious() {
        let set = SetModel(userID: userID, rpe: 9, rir: 1)
        SetSuggestionPolicy.materialize(
            set: set,
            previous: previousSet(rpe: 8, rir: 2),
            suggestionBacked: true,
            editedFields: [],
            effortLoggingEnabled: false
        )
        #expect(set.rpe == nil)
        #expect(set.rir == nil)
    }

    @Test func failureTrainingDefaultsOnlyUnratedNonWarmupSets() {
        let working = SetModel(userID: userID, setType: .working)
        SetSuggestionPolicy.materialize(
            set: working,
            previous: previousSet(rpe: 7, rir: 3),
            suggestionBacked: true,
            editedFields: [],
            failureTrainingEnabled: true
        )
        #expect(working.rpe == 10)
        #expect(working.rir == 0)

        let warmup = SetModel(userID: userID, setType: .warmup)
        SetSuggestionPolicy.materialize(
            set: warmup,
            previous: previousSet(rpe: 5),
            suggestionBacked: true,
            editedFields: [],
            failureTrainingEnabled: true
        )
        #expect(warmup.rpe == 5)
        #expect(warmup.rir == nil)

        let manuallyRated = SetModel(userID: userID, setType: .working, rpe: 8, rir: 2)
        SetSuggestionPolicy.materialize(
            set: manuallyRated,
            previous: previousSet(rpe: 10, rir: 0),
            suggestionBacked: true,
            editedFields: [],
            failureTrainingEnabled: true
        )
        #expect(manuallyRated.rpe == 8)
        #expect(manuallyRated.rir == 2)
    }
}
