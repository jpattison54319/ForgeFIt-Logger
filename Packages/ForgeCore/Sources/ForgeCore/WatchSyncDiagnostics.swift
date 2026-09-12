import Foundation

/// A small device-local operational history, intentionally without payloads,
/// workout identifiers, or Health data. It is excluded from backup keys.
public enum WatchSyncDiagnostics {
    private struct Event: Codable {
        var at: Date
        var kind: String
        var errorDomain: String?
        var errorCode: Int?
        var peer: WatchPeerInfo?
    }
    private static let key = "watch.sync.diagnostics.v1"

    public static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    public static func record(_ kind: String, error: Error? = nil, peer: WatchPeerInfo? = nil, defaults: UserDefaults = .standard) {
        var events = defaults.data(forKey: key).flatMap { WatchWire.decode([Event].self, from: $0) } ?? []
        let nsError = error as NSError?
        events.append(Event(at: Date(), kind: kind, errorDomain: nsError?.domain, errorCode: nsError?.code, peer: peer))
        if let data = WatchWire.encode(Array(events.suffix(32))) { defaults.set(data, forKey: key) }
    }
}
