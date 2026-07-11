import Foundation

/// What the user said they train during onboarding. Drives the pre-selected
/// starter program, the Home quick-start seeds, and the empty logger's
/// suggested exercises — so a lifter's fastest buttons are never four cardio
/// tiles. Stored in UserDefaults ("trainingFocusRaw"); changeable by simply
/// editing quick starts later, so it's a seed, not a cage.
enum TrainingFocus: String, CaseIterable, Identifiable {
    case strength, cardio, yoga, mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strength: "Strength"
        case .cardio: "Cardio"
        case .yoga: "Yoga"
        case .mixed: "Mixed"
        }
    }

    var systemImage: String {
        switch self {
        case .strength: "dumbbell.fill"
        case .cardio: "figure.run"
        case .yoga: "figure.yoga"
        case .mixed: "square.grid.2x2.fill"
        }
    }

    /// The starter program pre-selected for this focus (always deselectable).
    /// Yoga gets none — its plan is the built-in guided flows, not routines.
    var defaultProgramID: String? {
        switch self {
        case .strength: "full-body-foundation"
        case .cardio, .mixed: "hybrid-engine"
        case .yoga: nil
        }
    }

    /// Home quick-start seeds as `HomeQuickStartAction` id strings
    /// ("cardio:<modality>", "routine:<uuid>", "yoga:<flow-slug>") — must stay
    /// in sync with `HomeQuickStartAction.encode` in HomeView.
    func quickStartIDs(routineIDs: [UUID]) -> [String] {
        let routineActions = routineIDs.prefix(2).map { "routine:\($0.uuidString)" }
        switch self {
        case .strength:
            return routineActions + ["cardio:run", "cardio:walk"]
        case .cardio:
            return ["cardio:run", "cardio:cycle", "cardio:row", "cardio:walk"] + routineActions.prefix(1)
        case .yoga:
            return ["yoga:morning-wake-up", "yoga:hip-opener", "yoga:wind-down", "cardio:walk"]
        case .mixed:
            return Array(routineActions.prefix(1)) + ["cardio:run", "yoga:wind-down", "cardio:cycle"]
        }
    }

    /// Exercise slugs offered by the empty logger when the user has no
    /// history to suggest from — squat / push / pull staples that exist in
    /// the bundled library for every gym setup.
    var starterExerciseSlugs: [String] {
        switch self {
        case .cardio:
            ["Running_Treadmill", "Barbell_Squat", "Dumbbell_Bench_Press", "Wide-Grip_Lat_Pulldown"]
        default:
            ["Barbell_Squat", "Dumbbell_Bench_Press", "Wide-Grip_Lat_Pulldown", "One-Arm_Dumbbell_Row"]
        }
    }

    static var stored: TrainingFocus {
        UserDefaults.standard.string(forKey: "trainingFocusRaw")
            .flatMap(TrainingFocus.init(rawValue:)) ?? .mixed
    }
}
