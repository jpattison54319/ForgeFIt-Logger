import Foundation

/// The per-exercise progression rule a routine exercise follows. Stored as
/// JSON on `RoutineExerciseModel.progressionRuleJSON`; nil means
/// `.doubleProgression` — the zero-setup default.
public enum ProgressionRule: Codable, Equatable, Sendable {
    /// Work the routine's rep range; top it on every working set to earn a
    /// weight increase, then reset to the bottom of the range.
    case doubleProgression
    /// Add a fixed step (in display units) whenever all target reps are hit.
    case fixedIncrement(step: Double)
    /// Add a percentage whenever all target reps are hit, snapped to the
    /// increment grid.
    case percent(step: Double)
    /// No suggestions for this exercise.
    case off

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> ProgressionRule? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProgressionRule.self, from: data)
    }
}

/// Display-unit context for weight jumps: everything internal stays kg, but
/// steps and snapping happen in the unit the lifter reads, so a suggestion
/// never renders as 109.9 lb.
public struct ProgressionIncrement: Equatable, Sendable {
    /// Display units per kilogram (≈2.2046 for lb, 1 for kg).
    public let displayPerKilogram: Double
    /// Smallest jump in display units (5 lb barbell-class, 2.5 lb small; 2.5/1.25 kg).
    public let stepDisplay: Double
    /// Short suffix for rationale copy ("lb"/"kg").
    public let suffix: String

    public init(displayPerKilogram: Double, stepDisplay: Double, suffix: String) {
        self.displayPerKilogram = displayPerKilogram
        self.stepDisplay = stepDisplay
        self.suffix = suffix
    }
}

public struct ProgressionInput: Sendable {
    /// One completed WORKING set from the exercise's most recent session —
    /// weight is the mode-appropriate per-implement load (never doubled for
    /// unilateral), nil for pure bodyweight.
    public struct PerformedSet: Sendable {
        public let weightKg: Double?
        public let reps: Int?
        public init(weightKg: Double?, reps: Int?) {
            self.weightKg = weightKg
            self.reps = reps
        }
    }

    public let lastSessionSets: [PerformedSet]
    public let targetRepsLow: Int?
    public let targetRepsHigh: Int?
    public let rule: ProgressionRule
    public let increment: ProgressionIncrement
    /// True when the exercise carries no external load — weight suggestions
    /// are skipped and progression is reps-only.
    public let isBodyweight: Bool

    public init(
        lastSessionSets: [PerformedSet],
        targetRepsLow: Int?,
        targetRepsHigh: Int?,
        rule: ProgressionRule,
        increment: ProgressionIncrement,
        isBodyweight: Bool = false
    ) {
        self.lastSessionSets = lastSessionSets
        self.targetRepsLow = targetRepsLow
        self.targetRepsHigh = targetRepsHigh
        self.rule = rule
        self.increment = increment
        self.isBodyweight = isBodyweight
    }
}

public struct ProgressionSuggestion: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case increase, hold, addReps
    }

    public let kind: Kind
    /// Suggested working weight in kg (per implement); nil = keep current /
    /// bodyweight.
    public let weightKg: Double?
    public let repsLow: Int?
    public let repsHigh: Int?
    /// One plain-language line: "Hit 12 ≥ target 10 last time → +5 lb".
    public let rationale: String

    // Structs only get a memberwise init at `internal` access by default, so
    // without this, callers outside ForgeCore (e.g. the app's held-exercise
    // override) couldn't construct a suggestion of their own to hand back
    // through the same pipeline as an engine-produced one.
    public init(kind: Kind, weightKg: Double?, repsLow: Int?, repsHigh: Int?, rationale: String) {
        self.kind = kind
        self.weightKg = weightKg
        self.repsLow = repsLow
        self.repsHigh = repsHigh
        self.rationale = rationale
    }
}

/// Pure next-session target math. No models, no persistence — the app maps
/// SwiftData in and out.
public enum ProgressionEngine {

    public static func suggest(_ input: ProgressionInput) -> ProgressionSuggestion? {
        guard case .off = input.rule else {
            return computeSuggestion(input)
        }
        return nil
    }

    private static func computeSuggestion(_ input: ProgressionInput) -> ProgressionSuggestion? {
        let sets = input.lastSessionSets.filter { $0.reps != nil }
        guard !sets.isEmpty else { return nil }
        let reps = sets.compactMap(\.reps)
        let weights = sets.compactMap(\.weightKg).filter { $0 > 0 }
        let topWeightKg = weights.max()
        guard input.isBodyweight || topWeightKg != nil else { return nil }

        // Rep range: routine targets when set; otherwise anchor on last
        // session so exercises without programmed ranges still progress.
        let minReps = reps.min() ?? 0
        let low = input.targetRepsLow ?? input.targetRepsHigh ?? minReps
        let high = input.targetRepsHigh ?? input.targetRepsLow.map { $0 + 2 } ?? (minReps + 2)

        let allTopped = reps.allSatisfy { $0 >= high }
        let underCount = reps.filter { $0 < low }.count

        switch input.rule {
        case .off:
            return nil

        case .doubleProgression:
            if allTopped {
                return increase(from: topWeightKg, input: input, low: low, high: high,
                                because: "Hit \(reps.max() ?? high) ≥ target \(high) last time")
            }
            if underCount >= 2 {
                return ProgressionSuggestion(
                    kind: .hold, weightKg: topWeightKg, repsLow: low, repsHigh: high,
                    rationale: "\(underCount) sets under \(low) reps last time — own this weight first"
                )
            }
            return ProgressionSuggestion(
                kind: .addReps, weightKg: topWeightKg, repsLow: low, repsHigh: high,
                rationale: input.isBodyweight
                    ? "Top \(high) reps on every set to progress"
                    : "Top \(high) reps on every set to earn +\(format(input.increment.stepDisplay)) \(input.increment.suffix)"
            )

        case .fixedIncrement, .percent:
            let hitAll = reps.allSatisfy { $0 >= low }
            if hitAll {
                return increase(from: topWeightKg, input: input, low: low, high: high,
                                because: "Hit all target reps last time")
            }
            return ProgressionSuggestion(
                kind: .hold, weightKg: topWeightKg, repsLow: low, repsHigh: high,
                rationale: "Missed target reps last time — repeat this weight"
            )
        }
    }

    private static func increase(
        from weightKg: Double?,
        input: ProgressionInput,
        low: Int,
        high: Int,
        because reason: String
    ) -> ProgressionSuggestion? {
        // Bodyweight: earning the top of the range just moves the range up.
        guard !input.isBodyweight else {
            return ProgressionSuggestion(
                kind: .addReps, weightKg: nil, repsLow: low + 1, repsHigh: high + 1,
                rationale: "\(reason) → aim for \(low + 1)–\(high + 1) reps"
            )
        }
        guard let weightKg else { return nil }
        let inc = input.increment
        let display = weightKg * inc.displayPerKilogram
        let rawTarget: Double
        switch input.rule {
        case .percent(let step): rawTarget = display * (1 + step / 100)
        case .fixedIncrement(let step): rawTarget = display + step
        default: rawTarget = display + inc.stepDisplay
        }
        // Snap to the loadable grid and guarantee forward motion.
        var snapped = (rawTarget / inc.stepDisplay).rounded() * inc.stepDisplay
        if snapped <= display { snapped = display + inc.stepDisplay }
        let delta = snapped - display
        return ProgressionSuggestion(
            kind: .increase,
            weightKg: snapped / inc.displayPerKilogram,
            repsLow: low,
            repsHigh: high,
            rationale: "\(reason) → +\(format(delta)) \(inc.suffix) (\(format(snapped)) \(inc.suffix)) — back to \(low) reps, build to \(high)"
        )
    }

    private static func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
