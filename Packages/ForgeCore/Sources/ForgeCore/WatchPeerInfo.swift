import Foundation

public struct WatchPeerInfo: Codable, Equatable, Sendable {
    public var version: String
    public var build: String
    public var development: Bool

    public init(version: String, build: String, development: Bool) {
        self.version = version
        self.build = build
        self.development = development
    }

    public static var current: Self {
        #if DEBUG
        let development = true
        #else
        let development = false
        #endif
        return Self(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            development: development
        )
    }
}
