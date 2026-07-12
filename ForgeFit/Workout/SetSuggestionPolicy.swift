import ForgeData
import Foundation

/// The commit rule for placeholder-style suggested set values.
///
/// Suggested previous-session values render as grayed placeholders — they are
/// NOT in the model as user entries. This policy runs once, at the moment a
/// set is completed, and commits exactly what the placeholders were showing:
/// fields the user typed keep their typed values; untouched fields take the
/// suggestion; fields that displayed nothing commit nothing. Pure model
/// mutation with injected inputs so the whole matrix is unit-testable.
enum SetSuggestionPolicy {
    enum Field: Hashable {
        case weight
        /// Reps for strength sets / duration for cardio sets — one input box.
        case primary
    }

    /// - Parameters:
    ///   - set: the set being completed.
    ///   - previous: the matching set from the previous session (the source
    ///     of the displayed placeholders); nil when there's no history.
    ///   - suggestionBacked: true for routine-seeded sets whose stored
    ///     values are provisional targets (they display as placeholders); for
    ///     those, "untouched" is decided by `editedFields`. False for ad-hoc
    ///     sets, where any non-nil stored value is real and only nil fields
    ///     take their displayed placeholder.
    ///   - editedFields: fields the user explicitly entered (a field cleared
    ///     back to empty is un-marked by the caller — it returns to
    ///     suggestion state, keeping display and commit consistent).
    static func materialize(
        set: SetModel,
        previous: SetModel?,
        suggestionBacked: Bool,
        editedFields: Set<Field>
    ) {
        guard set.completedAt == nil else { return }
        // No previous session → the placeholders showed the set's own seeded
        // targets (already in the model) or nothing at all. Either way
        // there's nothing new to commit.
        guard let previous else { return }

        let weightUntouched = suggestionBacked
            ? !editedFields.contains(.weight)
            : set.weight == nil
        if weightUntouched {
            set.weight = previous.weight ?? set.weight
        }

        let primaryUntouched = suggestionBacked
            ? !editedFields.contains(.primary)
            : (set.reps == nil && set.durationSeconds == nil)
        if primaryUntouched {
            set.reps = previous.reps ?? set.reps
            set.durationSeconds = previous.durationSeconds ?? set.durationSeconds
        }

        // RPE/RIR placeholders only display on suggestion-backed rows, so
        // they only commit there — and a menu-picked value always wins.
        if suggestionBacked {
            set.rpe = set.rpe ?? previous.rpe
            set.rir = set.rir ?? previous.rir
        }
    }
}
