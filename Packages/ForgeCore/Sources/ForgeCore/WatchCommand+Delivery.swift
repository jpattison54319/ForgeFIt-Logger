import Foundation

extension WatchCommand {
    public var startsWorkout: Bool {
        switch self {
        case .startEmpty, .startRoutine, .startNextTrackedWorkout: true
        default: false
        }
    }

    /// Phone terminal notices are superseded by its latest committed graph.
    /// Watch-side logged edits and Health save receipts remain durable.
    public var isPhoneTerminalNotice: Bool {
        switch self {
        case .workoutFinished, .discardWorkout: true
        default: false
        }
    }
}
