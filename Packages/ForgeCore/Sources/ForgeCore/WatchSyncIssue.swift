import Foundation

public enum WatchSyncIssue: String, Codable, Sendable {
    case unreachable, timedOut, transport, incompatible, storageUnavailable, invalidPayload

    /// Reachability commonly drops during wake-up or when the phone sleeps.
    /// Only sustained failure during live work needs a recovery action.
    public var isTransient: Bool {
        switch self {
        case .unreachable, .timedOut, .transport: true
        case .incompatible, .storageUnavailable, .invalidPayload: false
        }
    }

    public var message: String {
        switch self {
        case .unreachable: "iPhone connection interrupted"
        case .timedOut, .transport: "Workout sync interrupted"
        case .incompatible: "Update ForgeFit on both devices"
        case .storageUnavailable: "Open ForgeFit on iPhone to restore access"
        case .invalidPayload: "Workout update could not be read"
        }
    }
}
