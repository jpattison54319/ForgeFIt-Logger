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
        SetSuggestionPolicy.materialize(set: set, previous: previousSet(rpe: 7), suggestionBacked: true, editedFields: [])
        #expect(set.rpe == 9)
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
}
