import Foundation

/// HealthKit's workout-scoped transport uses the same correlated handshake,
/// revision ordering, and metrics attribution as WatchConnectivity.
public enum WatchMirroringPacket: Codable, Sendable {
    case syncRequest(WatchSyncRequest)
    case syncReply(WatchSyncReply)
    case snapshot(Data, WatchSyncMetadata)
    case metrics(WatchLiveMetrics)

    public func encoded() -> Data? {
        guard let data = WatchWire.encode(self), data.count <= Self.maximumBytes else { return nil }
        return data
    }

    public static func decode(_ data: Data) -> Self? {
        guard data.count <= maximumBytes else { return nil }
        return WatchWire.decode(Self.self, from: data)
    }

    private static let maximumBytes = 256 * 1024
}
