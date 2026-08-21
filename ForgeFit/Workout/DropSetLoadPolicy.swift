import ForgeCore
import Foundation

/// Converts the load the lifter can currently see into a sensible editable
/// drop-set load. `sourceWeightKg` is the mode-specific entered/suggested
/// number: external load, added load, or assistance (always stored positive;
/// the assisted column supplies the visible minus sign).
enum DropSetLoadPolicy {
    /// Resolves the number actually painted in the load field. Routine-backed
    /// rows can retain a standing target in the model while intentionally
    /// showing a different previous-session suggestion as an empty-field
    /// placeholder; drop-set derivation must follow the visible value.
    static func visibleSourceWeight(
        enteredWeightKg: Double?,
        suggestedWeightKg: Double?,
        isShowingSuggestion: Bool
    ) -> Double? {
        isShowingSuggestion
            ? suggestedWeightKg
            : (enteredWeightKg ?? suggestedWeightKg)
    }

    static func suggestedModeWeight(
        sourceWeightKg: Double?,
        mode: WeightMode,
        bodyweightKg: Double?,
        displayUnit: WeightUnit
    ) -> Double? {
        guard let sourceWeightKg else { return nil }
        let source = max(0, sourceWeightKg)
        let sourceDisplay = displayUnit.displayValue(fromKilograms: source)
        let step = displayUnit == .lb ? 5.0 : 2.5

        switch mode {
        case .external:
            guard sourceDisplay > 0 else { return nil }
            return kilograms(
                fromRoundedDisplay: max(step, sourceDisplay * 0.75),
                step: step,
                unit: displayUnit
            )

        case .bodyweightAdded:
            // Less added weight means less effective load. Unlike an external
            // implement, zero is useful here: it intentionally drops to plain
            // bodyweight when the added load is smaller than one plate step.
            let rounded = max(0, (sourceDisplay * 0.75 / step).rounded() * step)
            return displayUnit.kilograms(fromDisplayValue: rounded)

        case .bodyweightAssisted:
            let targetKg: Double
            if let bodyweightKg, bodyweightKg > source {
                // Effective load is bodyweight - assistance. Reduce that load
                // by 25%, then convert back to the assistance number shown in
                // the -KG/-LB column.
                targetKg = bodyweightKg - 0.75 * (bodyweightKg - source)
            } else {
                // Bodyweight can be unavailable before HealthKit returns. A
                // conservative 25% assistance increase is still directionally
                // correct and avoids copying the same load into a "drop" row.
                targetKg = source * 1.25
            }
            let targetDisplay = displayUnit.displayValue(fromKilograms: targetKg)
            let rounded = max(
                sourceDisplay + step,
                (targetDisplay / step).rounded() * step
            )
            return displayUnit.kilograms(fromDisplayValue: rounded)

        case .bodyweight:
            // Pure bodyweight has no numeric load field to prefill.
            return nil
        }
    }

    private static func kilograms(
        fromRoundedDisplay value: Double,
        step: Double,
        unit: WeightUnit
    ) -> Double {
        let rounded = (value / step).rounded() * step
        return unit.kilograms(fromDisplayValue: rounded)
    }
}
