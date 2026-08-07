import Foundation

/// The single authoritative answer to "what should I do today?" The numeric
/// recovery-signal index remains a versioned product index; check-ins shape the guidance but
/// do not pretend to be calibrated sensor data. A "Sick" check-in is the one
/// safety override because the user has explicitly reported an illness.
nonisolated struct TodayVerdict: Equatable {
    let action: RecoveryEngine.Action
    let recommendation: String
    let preWorkoutAdjustment: String
    let isCheckinOverride: Bool

    static func make(score: Double?, checkinTags: [String]) -> TodayVerdict {
        if checkinTags.contains("sick") {
            return TodayVerdict(
                action: .deloadRecover,
                recommendation: "You marked yourself sick today. Skip planned training and prioritize recovery.",
                preWorkoutAdjustment: "Recovery day; skip planned training.",
                isCheckinOverride: true
            )
        }

        guard let score else {
            return TodayVerdict(
                action: .insufficientData,
                recommendation: "Not enough comparable data for a recovery index yet. Use symptoms, your warm-up, planned effort, and performance to decide.",
                preWorkoutAdjustment: "Baseline building; use your warm-up and planned effort to decide.",
                isCheckinOverride: false
            )
        }

        let action: RecoveryEngine.Action = switch score {
        case ..<0.65: .reduceVolume
        default: .trainAsPlanned
        }

        let base: (recommendation: String, adjustment: String) = switch action {
        case .insufficientData:
            (
                "Not enough comparable data for a recovery index yet. Use symptoms, your warm-up, planned effort, and performance to decide.",
                "Baseline building; use your warm-up and planned effort to decide."
            )
        case .push:
            (
                "An optional small progression is only appropriate if today’s warm-up performance is at least typical and warm-up effort is not elevated. Do not add unplanned volume.",
                "Use warm-up performance—not the morning index—to decide on any small progression."
            )
        case .trainAsPlanned:
            (
                score >= 0.85
                    ? "No recovery-based restriction was detected. This does not guarantee performance; use your warm-up to confirm."
                    : "Proceed as planned and use your warm-up to confirm how today feels.",
                "Proceed as planned; use your warm-up to confirm."
            )
        case .reduceVolume:
            (
                score < 0.5
                    ? "Several recovery signals are adverse. Consider reducing intensity or volume if symptoms or warm-up performance agree."
                    : "Recovery signals are mixed. Begin conservatively and reassess during your warm-up.",
                "Begin conservatively and reassess during your warm-up."
            )
        case .deloadRecover:
            (
                "Recovery is not lining up with another hard session. Choose Zone 2, mobility, or a full rest day.",
                "Deload/recover; choose Zone 2, mobility, or rest."
            )
        }

        let checkinContext = context(for: checkinTags)
        return TodayVerdict(
            action: action,
            recommendation: checkinContext.map { base.recommendation + " Check-in: \($0)." } ?? base.recommendation,
            preWorkoutAdjustment: checkinContext.map { base.adjustment + " Check-in: \($0)." } ?? base.adjustment,
            isCheckinOverride: false
        )
    }

    private static func context(for tags: [String]) -> String? {
        let labels = tags.compactMap { tag -> String? in
            switch tag {
            case "feeling-great": "feeling great"
            case "slept-badly": "slept badly"
            case "sore": "sore"
            case "stressed": "stressed"
            case "alcohol": "alcohol last night"
            default: nil
            }
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }
}
