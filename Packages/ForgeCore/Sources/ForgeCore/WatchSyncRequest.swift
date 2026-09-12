import Foundation

public struct WatchSyncRequest: Codable, Equatable, Sendable {
    public static let protocolVersion = 1
    public var id: UUID
    public var protocolVersion: Int
    public var peer: WatchPeerInfo

    public init(id: UUID = UUID(), peer: WatchPeerInfo = .current) {
        self.id = id
        protocolVersion = Self.protocolVersion
        self.peer = peer
    }
}
