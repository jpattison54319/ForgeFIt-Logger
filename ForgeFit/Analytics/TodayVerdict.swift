import Foundation

/// The single authoritative answer to "what should I do today?" The numeric
/// readiness score remains biometric-derived; check-ins shape the guidance but
/// do not pretend to be calibrated sensor data. A "Sick" check-in is the one
/// safety override because the user has explicitly reported an illness.
struct TodayVerdict: Equatable {
    let action: RecoveryEngine.Action
    let recommendation: String
    let preWorkoutAdjustment: String
    let isCheckinOverride: Bool

    static func make(score: Double, checkinTags: [String]) -> TodayVerdict {
        if checkinTags.contains("sick") {
            return TodayVerdict(
                action: .deloadRecover,
                recommendation: "You marked yourself sick today. Skip planned training and prioritize recovery.",
                preWorkoutAdjustment: "Recovery day; skip planned training.",
                isCheckinOverride: true
            )
        }

        let action: RecoveryEngine.Action = switch score {
        case ..<0.40: .deloadRecover
        case ..<0.70: .reduceVolume
        case ..<0.85: .trainAsPlanned
        default: .push
        }

        let base: (recommendation: String, adjustment: String) = switch action {
        case .push:
            (
                "Exceptional recovery today. Keep the planned session and make one priority lift or interval harder; do not add extra volume.",
                "Push one priority top set or interval; keep total volume planned."
            )
        case .trainAsPlanned:
            (
                "Train as planned. Use warm-ups and your logged effort to adjust individual muscles by feel.",
                "Train as planned."
            )
        case .reduceVolume:
            (
                "Recovery is below your ready range today. Keep movement quality high, drop one or two sets, and avoid PR attempts.",
                "Reduce volume; drop 1–2 sets or cap hard work at RPE 8."
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
