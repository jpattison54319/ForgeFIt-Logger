import ForgeCore
import Foundation

/// One place that turns a raw engine value into user-facing text, keyed by
/// the metric's value kind — axes, selection callouts, period cards, and the
/// advanced panel all speak display units (mass via `Fmt`, never hand-rolled
/// conversion; storage stays kilograms).
enum InsightValueFormat {

    /// Compact axis ticks omit the repeated unit. The adjacent axis title
    /// names that unit once; exact-value callouts continue using `string`.
    static func axisString(
        _ value: Double,
        kind: InsightValueKind?,
        weightUnit: WeightUnit? = nil,
        modality: String? = nil
    ) -> String {
        guard let kind else { return value.insightFormatted }
        let resolvedWeightUnit = weightUnit ?? Fmt.unit
        switch kind {
        case .massKilograms, .massPerMinute:
            return resolvedWeightUnit.displayValue(fromKilograms: value)
                .formatted(.number.precision(.fractionLength(0...1)))
        case .distanceMeters:
            return Fmt.distanceUnit.distance(fromMeters: value)
                .formatted(.number.precision(.fractionLength(0...1)))
        case .elevationMeters:
            return Int(value.rounded()).formatted()
        case .speed:
            return (Fmt.distanceUnit.distance(fromMeters: value) * 3_600)
                .formatted(.number.precision(.fractionLength(0...1)))
        case .pace:
            return paceClock(secondsPerMeter: value, modality: modality)
        case .durationSeconds:
            let total = Int(value.rounded())
            return String(format: "%d:%02d", total / 60, total % 60)
        case .sessions, .trainingDays, .reps, .steps, .heartRateBPM,
             .heartRateVariabilityMS, .energyKilocalories, .power, .cadence,
             .percentage, .readinessScore:
            return Int(value.rounded()).formatted()
        case .bodyweightMultiple, .breathsPerMinute, .rpe, .rir, .count, .score:
            return value.insightFormatted
        }
    }

    static func axisUnitLabel(
        kind: InsightValueKind?,
        weightUnit: WeightUnit? = nil,
        modality: String? = nil
    ) -> String? {
        guard let kind else { return nil }
        let resolvedWeightUnit = weightUnit ?? Fmt.unit
        return switch kind {
        case .count, .score: nil
        case .sessions: "sessions"
        case .trainingDays: "days"
        case .reps: "reps"
        case .steps: "steps"
        case .massKilograms: resolvedWeightUnit.shortSuffix
        case .massPerMinute: "\(resolvedWeightUnit.shortSuffix)/min"
        case .bodyweightMultiple: "× bodyweight"
        case .durationSeconds: "min:sec"
        case .distanceMeters: Fmt.distanceUnit.abbreviation
        case .elevationMeters: "m"
        case .pace: paceAxisUnit(modality: modality)
        case .speed: Fmt.distanceUnit.speedSuffix
        case .heartRateBPM: "bpm"
        case .heartRateVariabilityMS: "ms"
        case .percentage: "%"
        case .energyKilocalories: "kcal"
        case .power: "W"
        case .cadence: "spm"
        case .breathsPerMinute: "br/min"
        case .rpe: "RPE /10"
        case .rir: "RIR"
        case .readinessScore: "/100"
        }
    }

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
        let denominatorMeters = paceDenominator(modality: modality)
        let suffix = paceSuffix(modality: modality)
        let secondsPerUnit = secondsPerMeter * denominatorMeters
        let total = Int(secondsPerUnit.rounded())
        return String(format: "%d:%02d%@", total / 60, total % 60, suffix)
    }

    private static func paceClock(secondsPerMeter: Double, modality: String?) -> String {
        guard secondsPerMeter > 0 else { return "—" }
        let total = Int((secondsPerMeter * paceDenominator(modality: modality)).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func paceDenominator(modality: String?) -> Double {
        return switch modality.map({ CardioKind.from(modality: $0) }) {
        case .row: 500
        case .swim: 100
        default: Fmt.distanceUnit.meters(fromDistance: 1)
        }
    }

    private static func paceSuffix(modality: String?) -> String {
        return switch modality.map({ CardioKind.from(modality: $0) }) {
        case .row: "/500m"
        case .swim: "/100m"
        default: "/\(Fmt.distanceUnit.abbreviation)"
        }
    }

    private static func paceAxisUnit(modality: String?) -> String {
        return switch modality.map({ CardioKind.from(modality: $0) }) {
        case .row: "min/500m"
        case .swim: "min/100m"
        default: "min/\(Fmt.distanceUnit.abbreviation)"
        }
    }
}
