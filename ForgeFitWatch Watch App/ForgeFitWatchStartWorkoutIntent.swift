import AppIntents
import ForgeCore

enum ForgeFitWatchWorkoutStyle: String, AppEnum {
    case nextTracked
    case empty

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workout Type")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .nextTracked: DisplayRepresentation(
            title: "Next Tracked Workout",
            subtitle: "From your active microcycle",
            image: .init(systemName: "forward.fill")
        ),
        .empty: DisplayRepresentation(
            title: "Empty Workout",
            subtitle: "Build it as you train",
            image: .init(systemName: "square.and.pencil")
        ),
    ]
}

struct ForgeFitWatchStartWorkoutIntent: StartWorkoutIntent {
    static let title: LocalizedStringResource = "Start ForgeFit Workout"
    static let description = IntentDescription(
        "Starts a ForgeFit workout through your reachable phone."
    )
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Workout")
    var workoutStyle: ForgeFitWatchWorkoutStyle

    static var suggestedWorkouts: [Self] {
        [Self(style: .nextTracked), Self(style: .empty)]
    }

    var displayRepresentation: DisplayRepresentation {
        ForgeFitWatchWorkoutStyle.caseDisplayRepresentations[workoutStyle]
            ?? DisplayRepresentation(title: "ForgeFit Workout")
    }

    init() {
        workoutStyle = .nextTracked
    }

    init(style: ForgeFitWatchWorkoutStyle) {
        workoutStyle = style
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let command: WatchCommand = switch workoutStyle {
        case .nextTracked: .startNextTrackedWorkout
        case .empty: .startEmpty
        }
        let result = await WatchStore.shared.requestImmediateStart(command)
        switch result {
        case .started(let title):
            return .result(dialog: "Started \(title).")
        case .activeWorkout(let title):
            return .result(dialog: "\(title) is already in progress. Open ForgeFit to resume it.")
        case .chooseWorkout(let message), .unavailable(let message):
            return .result(dialog: "\(message)")
        }
    }
}
