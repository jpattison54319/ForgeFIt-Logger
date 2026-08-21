import ForgeCore
import ForgeData
import Foundation

/// The one resolved rep suggestion a live row renders, increments from, and
/// may materialize at completion. Percentage prescriptions are plan-led;
/// legacy fixed-load rows remain history-led.
struct RepFieldSuggestion: Equatable {
    let materializedValue: Int?
    let placeholder: String
    let quickAdjustmentBase: Int?
}

enum RepSuggestionPolicy {
    static func resolve(
        set: SetModel,
        previousReps: Int?,
        progressionLeads: Bool,
        structuredOverride: Int? = nil
    ) -> RepFieldSuggestion {
        if let structuredOverride {
            return exact(structuredOverride)
        }

        if set.loadPrescriptionMode == .percentEstimatedOneRepMax,
           !set.setType.isBlockType,
           set.setType != .amrap {
            guard let target = set.prescribedRepTarget else {
                // Percentage workouts created before rep targets were
                // snapshotted already carry their planned exact reps here.
                if let reps = set.reps {
                    return exact(reps)
                }
                return RepFieldSuggestion(
                    materializedValue: nil,
                    placeholder: "—",
                    quickAdjustmentBase: nil
                )
            }
            return RepFieldSuggestion(
                materializedValue: target.exactValue,
                placeholder: target.displayText,
                quickAdjustmentBase: target.lowerBound
            )
        }

        let value = progressionLeads
            ? (set.reps ?? previousReps)
            : (previousReps ?? set.reps)
        guard let value else {
            return RepFieldSuggestion(
                materializedValue: nil,
                placeholder: "—",
                quickAdjustmentBase: nil
            )
        }
        return exact(value)
    }

    private static func exact(_ value: Int) -> RepFieldSuggestion {
        RepFieldSuggestion(
            materializedValue: value,
            placeholder: String(value),
            quickAdjustmentBase: value
        )
    }
}
