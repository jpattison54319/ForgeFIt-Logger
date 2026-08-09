import Foundation

/// Natural-language goal completion phrases, kept in ForgeCore so exact audio
/// wording is testable without constructing an AVAudioSession.
public enum CardioSessionGoalAnnouncement {
    public static func phrase(
        for goal: IntervalPlan.SessionGoal,
        distanceUnit: DistanceUnit,
        usesFixedMeters: Bool = false
    ) -> String {
        switch goal.kind {
        case .distance:
            let spokenDistance: String
            if usesFixedMeters {
                spokenDistance = quantity(goal.value, singular: "meter", plural: "meters")
            } else {
                spokenDistance = quantity(
                    distanceUnit.distance(fromMeters: goal.value),
                    singular: distanceUnit == .mi ? "mile" : "kilometer",
                    plural: distanceUnit == .mi ? "miles" : "kilometers"
                )
            }
            return "You hit your distance goal of \(spokenDistance)."
        case .duration:
            return "You hit your time goal of \(PaceAnnouncement.spokenDuration(Int(goal.value.rounded())))."
        case .calories:
            return "You hit your calorie goal of \(quantity(goal.value, singular: "calorie", plural: "calories"))."
        case .elevation:
            return "You hit your climb goal of \(quantity(goal.value, singular: "meter", plural: "meters"))."
        }
    }

    private static func quantity(_ value: Double, singular: String, plural: String) -> String {
        let rounded = value.formatted(
            .number
                .precision(.fractionLength(0...2))
                .locale(Locale(identifier: "en_US_POSIX"))
        )
        let unit = abs(value - 1) < 0.000_001 ? singular : plural
        return "\(rounded) \(unit)"
    }
}
