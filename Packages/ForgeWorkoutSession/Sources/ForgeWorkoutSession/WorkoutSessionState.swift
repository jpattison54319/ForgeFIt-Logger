import Foundation

public enum WorkoutSessionState: String, Codable, Sendable {
    case idle
    case preparing
    case active
    case paused
    case ending
    case ended
    case failed
}
