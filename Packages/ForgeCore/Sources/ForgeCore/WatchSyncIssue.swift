import Foundation

public enum WatchSyncIssue: String, Codable, Sendable {
    case unreachable, timedOut, transport, incompatible, storageUnavailable, invalidPayload

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
