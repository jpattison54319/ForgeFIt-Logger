import Foundation

/// Ordering is owned by the phone process. A new epoch is trusted only after
/// a correlated reply, so delayed packets from a replaced process cannot win.
public struct WatchSyncMetadata: Codable, Equatable, Sendable {
    public var epoch: UUID
    public var revision: UInt64
    public var workoutID: UUID?
    public var protocolVersion: Int
    public var peer: WatchPeerInfo

    public init(epoch: UUID, revision: UInt64, workoutID: UUID?, peer: WatchPeerInfo = .current) {
        self.epoch = epoch
        self.revision = revision
        self.workoutID = workoutID
        protocolVersion = WatchSyncRequest.protocolVersion
        self.peer = peer
    }
}
