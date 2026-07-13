import ForgeCore
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

    /// The exact placeholders rendered by a set row. Keeping these explicit
    /// makes completion commit what the user saw even when progression, weight
    /// mode, or an external completion changes where the suggestion came from.
    struct SuggestedValues {
        var weight: Double?
        var reps: Int?
        var durationSeconds: Int?
        var rpe: Double?
        var rir: Int?

        init(
            weight: Double? = nil,
            reps: Int? = nil,
            durationSeconds: Int? = nil,
            rpe: Double? = nil,
            rir: Int? = nil
        ) {
            self.weight = weight
            self.reps = reps
            self.durationSeconds = durationSeconds
            self.rpe = rpe
            self.rir = rir
        }
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
        editedFields: Set<Field>,
        effortLoggingEnabled: Bool = true,
        failureTrainingEnabled: Bool = false
    ) {
        materialize(
            set: set,
            suggestions: SuggestedValues(
                weight: previous.flatMap(weightValue),
                reps: previous?.reps,
                durationSeconds: previous?.durationSeconds,
                rpe: previous?.rpe,
                rir: previous?.rir
            ),
            suggestionBacked: suggestionBacked,
            editedFields: editedFields,
            effortLoggingEnabled: effortLoggingEnabled,
            failureTrainingEnabled: failureTrainingEnabled
        )
    }

    static func materialize(
        set: SetModel,
        suggestions: SuggestedValues,
        suggestionBacked: Bool,
        editedFields: Set<Field>,
        effortLoggingEnabled: Bool = true,
        failureTrainingEnabled: Bool = false,
        allowsCompletedSet: Bool = false
    ) {
        guard allowsCompletedSet || set.completedAt == nil else { return }

        let weightUntouched = suggestionBacked
            ? !editedFields.contains(.weight)
            : weightValue(set) == nil
        if weightUntouched, let weight = suggestions.weight {
            setWeight(weight, on: set)
        }

        let primaryUntouched = suggestionBacked
            ? !editedFields.contains(.primary)
            : (set.reps == nil && set.durationSeconds == nil)
        if primaryUntouched {
            if let reps = suggestions.reps { set.reps = reps }
            if let durationSeconds = suggestions.durationSeconds {
                set.durationSeconds = durationSeconds
            }
        }

        // Hidden means absent. This also clears a routine-seeded effort target
        // or a value entered earlier in the workout before the setting changed.
        guard effortLoggingEnabled else {
            set.rpe = nil
            set.rir = nil
            return
        }

        // Failure training supplies a default only when the user has not
        // already picked another effort. Warm-up sets never inherit it.
        if failureTrainingEnabled, set.setType != .warmup {
            if set.rpe == nil, set.rir == nil {
                set.rpe = 10
                set.rir = 0
            }
            return
        }

        // Normal RPE/RIR placeholders only display on suggestion-backed rows,
        // so they only commit there, and a menu-picked value always wins.
        if suggestionBacked, set.rpe == nil, set.rir == nil {
            set.rpe = suggestions.rpe
            set.rir = suggestions.rir
        }
    }

    private static func weightValue(_ set: SetModel) -> Double? {
        switch set.weightMode {
        case .external: set.weight
        case .bodyweightAdded: set.addedWeight
        case .bodyweightAssisted: set.assistanceWeight
        case .bodyweight: nil
        }
    }

    private static func setWeight(_ value: Double, on set: SetModel) {
        switch set.weightMode {
        case .external: set.weight = value
        case .bodyweightAdded: set.addedWeight = value
        case .bodyweightAssisted: set.assistanceWeight = value
        case .bodyweight: break
        }
    }
}
