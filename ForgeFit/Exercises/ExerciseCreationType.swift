import ForgeCore

enum ExerciseCreationType: String, CaseIterable {
    case lift = "Lift"
    case timedStrength = "Timed"
    case distanceStrength = "Distance"
    case cardio = "Cardio"
    case yoga = "Yoga"

    init(modality: Modality, isTimedStrength: Bool = false, isDistanceStrength: Bool = false) {
        switch modality {
        case .strength:
            self = isDistanceStrength ? .distanceStrength : (isTimedStrength ? .timedStrength : .lift)
        case .cardio: self = .cardio
        case .yoga: self = .yoga
        }
    }

    var modality: Modality {
        switch self {
        case .lift, .timedStrength, .distanceStrength: .strength
        case .cardio: .cardio
        case .yoga: .yoga
        }
    }
}
