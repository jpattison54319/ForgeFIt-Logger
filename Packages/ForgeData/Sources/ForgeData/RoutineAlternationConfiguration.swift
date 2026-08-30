import Foundation

/// Atomic, ordered membership for one alternating-routine cycle.
///
/// A member's join date prevents workouts completed before that routine was
/// added from unexpectedly changing which routine is due next. The payload is
/// versioned so the CloudKit-backed model can evolve without adding a child
/// relationship or rewriting legacy two-routine records eagerly.
public struct RoutineAlternationConfiguration: Codable, Equatable, Sendable {
    public struct Member: Codable, Equatable, Sendable {
        public let routineID: UUID
        public let joinedAt: Date

        public init(routineID: UUID, joinedAt: Date) {
            self.routineID = routineID
            self.joinedAt = joinedAt
        }
    }

    public static let currentVersion = 1

    public let version: Int
    public var members: [Member]

    public init(
        version: Int = Self.currentVersion,
        members: [Member]
    ) {
        self.version = version
        self.members = members
    }

    public init(memberRoutineIDs: [UUID], joinedAt: Date) {
        self.init(members: memberRoutineIDs.map {
            Member(routineID: $0, joinedAt: joinedAt)
        })
    }

    public static func decode(from json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
