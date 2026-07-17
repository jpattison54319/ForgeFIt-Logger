import ForgeCore
import Foundation

/// One place that turns a raw engine value into user-facing text, keyed by
/// the metric's value kind — axes, selection callouts, period cards, and the
/// advanced panel all speak display units (mass via `Fmt`, never hand-rolled
/// conversion; storage stays kilograms).
enum InsightValueFormat {

    static func string(
        _ value: Double,
        kind: InsightValueKind?,
        weightUnit: WeightUnit? = nil,
        modality: String? = nil
    ) -> String {
        guard let kind else { return value.insightFormatted }
        let resolvedWeightUnit = weightUnit ?? Fmt.unit
        switch kind {
        case .count:
            return value.insightFormatted
        case .sessions:
            return count(value, singular: "session", plural: "sessions")
        case .trainingDays:
            return count(value, singular: "day", plural: "days")
        case .reps:
            return count(value, singular: "rep", plural: "reps")
        case .steps:
            return count(value, singular: "step", plural: "steps")
        case .massKilograms:
            return Fmt.volume(value, unit: resolvedWeightUnit)
        case .massPerMinute:
            let display = resolvedWeightUnit.displayValue(fromKilograms: value)
            return "\(display.formatted(.number.precision(.fractionLength(0...1)))) \(resolvedWeightUnit.shortSuffix)/min"
        case .bodyweightMultiple:
            return "\(value.formatted(.number.precision(.fractionLength(0...2))))\u{00d7} BW"
        case .durationSeconds:
            return Fmt.durationShort(Int(value.rounded()))
        case .distanceMeters:
            return Fmt.distance(value)
        case .pace:
            return paceString(secondsPerMeter: value, modality: modality)
        case .speed:
            let distancePerHour = Fmt.distanceUnit.distance(fromMeters: value) * 3_600
            return "\(distancePerHour.formatted(.number.precision(.fractionLength(0...1)))) \(Fmt.distanceUnit.abbreviation)/h"
        case .heartRateBPM:
            return "\(Int(value.rounded())) bpm"
        case .heartRateVariabilityMS:
            return "\(Int(value.rounded())) ms"
        case .percentage:
            return "\(value.formatted(.number.precision(.fractionLength(0...1))))%"
        case .energyKilocalories:
            return "\(Int(value.rounded())) kcal"
        case .power:
            return "\(Int(value.rounded())) W"
        case .cadence:
            return "\(Int(value.rounded())) spm"
        case .elevationMeters:
            return "\(Int(value.rounded())) m"
        case .breathsPerMinute:
            return "\(value.formatted(.number.precision(.fractionLength(0...1)))) br/min"
        case .rpe:
            return "RPE \(value.formatted(.number.precision(.fractionLength(0...1))))/10"
        case .rir:
            return "RIR \(value.formatted(.number.precision(.fractionLength(0...1))))"
        case .readinessScore:
            return "\(Int(value.rounded()))/100"
        case .score:
            return value.insightFormatted
        }
    }

    private static func count(_ value: Double, singular: String, plural: String) -> String {
        let rounded = value.rounded()
        let number = abs(value - rounded) < 0.000_001
            ? Int(rounded).formatted()
            : value.insightFormatted
        return "\(number) \(abs(value - 1) < 0.000_001 ? singular : plural)"
    }

    /// Engine pace is seconds per meter. The denominator is part of the
    /// metric's meaning, not mere presentation: rowing speaks /500 m,
    /// swimming /100 m, and ordinary distance activities follow the user's
    /// km/mi preference.
    static func paceString(secondsPerMeter: Double, modality: String? = nil) -> String {
        guard secondsPerMeter > 0 else { return "—" }
        let kind = modality.map { CardioKind.from(modality: $0) }
        let denominatorMeters: Double
        let suffix: String
        switch kind {
        case .row:
            denominatorMeters = 500
            suffix = "500m"
        case .swim:
            denominatorMeters = 100
            suffix = "100m"
        default:
            denominatorMeters = Fmt.distanceUnit.meters(fromDistance: 1)
            suffix = Fmt.distanceUnit.abbreviation
        }
        let secondsPerUnit = secondsPerMeter * denominatorMeters
        let total = Int(secondsPerUnit.rounded())
        return String(format: "%d:%02d/%@", total / 60, total % 60, suffix)
    }
}
