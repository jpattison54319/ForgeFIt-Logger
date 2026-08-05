enum ConditioningCompletionContext {
    case workout
    case block

    var liveActionTitle: String {
        switch self {
        case .workout: "Finish Workout"
        case .block: "Finish Conditioning"
        }
    }

    var resultTitle: String {
        switch self {
        case .workout: "Workout Result"
        case .block: "Conditioning Result"
        }
    }

    var commitTitle: String {
        switch self {
        case .workout: "Save Workout"
        case .block: "Complete Conditioning"
        }
    }

    var returnTitle: String {
        switch self {
        case .workout: "Keep Logging"
        case .block: "Back to Conditioning"
        }
    }

    var minimizeAccessibilityLabel: String {
        switch self {
        case .workout: "Minimize workout"
        case .block: "Return to mixed workout"
        }
    }

    var failureTitle: String {
        switch self {
        case .workout: "Couldn't Save Workout"
        case .block: "Couldn't Complete Conditioning"
        }
    }

    var failureFallback: String {
        switch self {
        case .workout: "Your workout is still active."
        case .block: "Your conditioning block is still active."
        }
    }
}
