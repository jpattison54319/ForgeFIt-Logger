import ForgeCore
import ForgeData
import Foundation

/// Textual presentation for saved routine targets. Keeping this separate from
/// the row makes the read-only detail, accessibility, and tests agree on what
/// each persisted set shape means.
enum RoutineSetPresentation {
    static func badgeText(for set: RoutineSetModel, at index: Int, in sets: [RoutineSetModel]) -> String {
        let style = SetTypeStyle.of(set.setType)
        guard style.numbered else { return style.badge.isEmpty ? "•" : style.badge }
        let number = sets.prefix(index + 1).filter { SetTypeStyle.of($0.setType).numbered }.count
        return "\(number)\(style.badge)"
    }

    static func repsText(
        for set: RoutineSetModel, defaultHoldSeconds: Int? = nil, tracksDistance: Bool = false
    ) -> String {
        if set.setType == .distance || tracksDistance {
            let unit = StrengthDistanceUnit(rawValue: UserDefaults.standard.string(
                forKey: StrengthDistanceUnit.preferenceKey
            ) ?? "") ?? .meters
            return set.targetDistanceMeters.map { unit.label(meters: $0) } ?? "—"
        }
        if set.setType == .timedHold || defaultHoldSeconds != nil {
            return Fmt.elapsed(StrengthHold.validSeconds(set.targetDurationSeconds)
                ?? defaultHoldSeconds ?? StrengthHold.defaultSeconds)
        }
        switch set.setType {
        case .myoRep:
            if let minis = set.plannedMiniSetCount {
                return "Activation + \(minis) mini\(minis == 1 ? "" : "s")"
            }
            return "Activation + minis"
        case .restPause:
            return "Activation + minis"
        case .cluster:
            let plan = set.plannedMiniReps
            return plan.isEmpty ? "Cluster reps" : plan.map(String.init).joined(separator: "+")
        case .amrap:
            if let seconds = set.targetDurationSeconds {
                return "Max reps in \(Fmt.durationShort(seconds))"
            }
            return "Max reps"
        default:
            switch (set.targetRepsLow, set.targetRepsHigh) {
            case let (low?, high?) where low != high: return "\(low)–\(high)"
            case let (low?, _): return "\(low)"
            case let (_, high?): return "\(high)"
            default: return "—"
            }
        }
    }

    static func effortText(for set: RoutineSetModel) -> String {
        if let rpe = set.targetRPE {
            return "RPE \(rpe.formatted(.number.precision(.fractionLength(0...1))))"
        }
        if let rir = set.targetRIR { return "\(rir) RIR" }
        return "—"
    }
}
