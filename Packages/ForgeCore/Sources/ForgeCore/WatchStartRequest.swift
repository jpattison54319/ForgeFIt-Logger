import Foundation

/// A user-initiated start is short lived and never enters durable delivery.
/// Its identity is the resulting workout identity, making duplicate delivery
/// idempotent even after either process restarts.
public struct WatchStartRequest: Codable, Sendable {
    public static let maximumAge: TimeInterval = 8
    public let id: UUID
    public let issuedAt: Date
    public let command: WatchCommand

    public init(id: UUID = UUID(), issuedAt: Date = Date(), command: WatchCommand) {
        self.id = id
        self.issuedAt = issuedAt
        self.command = command
    }

    public func isValid(at now: Date) -> Bool {
        let age = now.timeIntervalSince(issuedAt)
        return command.startsWorkout && age.isFinite && age >= -2 && age < Self.maximumAge
    }
}
