import Foundation
import Observation

@MainActor
@Observable
final class FeatureDiscoveryStore {
    static let defaultsKey = "featureDiscoveryState.v1"
    static let shared = FeatureDiscoveryStore()

    enum Status: String, Codable, Equatable, Sendable {
        case adopted
        case dismissed
    }

    struct FeatureState: Codable, Equatable, Sendable {
        let status: Status
        let changedAt: Date
    }

    struct Record: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        var enrolledAt: Date
        var features: [String: FeatureState]

        init(enrolledAt: Date) {
            schemaVersion = Self.currentSchemaVersion
            self.enrolledAt = enrolledAt
            features = [:]
        }
    }

    private(set) var revision = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var record: Record
    @ObservationIgnored private var loadedJSON: String?

    init(defaults: UserDefaults = .standard, now: Date = .now) {
        self.defaults = defaults
        let loaded = Self.load(from: defaults, now: now)
        record = loaded.record
        loadedJSON = loaded.json
        if loaded.shouldPersist {
            persist()
        }
    }

    var enrolledAt: Date { record.enrolledAt }

    func status(for feature: FeatureDiscoveryID) -> Status? {
        record.features[feature.rawValue]?.status
    }

    func dismiss(_ feature: FeatureDiscoveryID, now: Date = .now) {
        setStatus(.dismissed, for: feature, now: now)
    }

    func markAdopted(_ feature: FeatureDiscoveryID, now: Date = .now) {
        setStatus(.adopted, for: feature, now: now)
    }

    /// Backup restore writes UserDefaults directly. Reload only at a semantic
    /// evaluation boundary so JSON work never enters the SwiftUI render path.
    func reloadIfChanged(now: Date = .now) {
        let currentJSON = defaults.string(forKey: Self.defaultsKey)
        guard currentJSON != loadedJSON else { return }
        let loaded = Self.load(from: defaults, now: now)
        record = loaded.record
        loadedJSON = loaded.json
        if loaded.shouldPersist {
            persist()
        }
        revision &+= 1
    }

    /// Account reset is a new discovery enrollment boundary. This also keeps
    /// the live singleton aligned with defaults removed outside the store.
    func resetEnrollment(now: Date = .now) {
        defaults.removeObject(forKey: Self.defaultsKey)
        record = Record(enrolledAt: now)
        loadedJSON = nil
        persist()
        revision &+= 1
    }

    #if DEBUG
    func replaceForTesting(enrolledAt: Date) {
        record = Record(enrolledAt: enrolledAt)
        persist()
        revision &+= 1
    }
    #endif

    private func setStatus(_ status: Status, for feature: FeatureDiscoveryID, now: Date) {
        if record.features[feature.rawValue]?.status == status { return }
        // Adoption is durable evidence of use and must never be weakened by a
        // later stale dismissal action.
        if record.features[feature.rawValue]?.status == .adopted { return }
        record.features[feature.rawValue] = FeatureState(status: status, changedAt: now)
        persist()
        revision &+= 1
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(record),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
        loadedJSON = json
    }

    private static func load(
        from defaults: UserDefaults,
        now: Date
    ) -> (record: Record, json: String?, shouldPersist: Bool) {
        guard let json = defaults.string(forKey: defaultsKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Record.self, from: data),
              decoded.schemaVersion == Record.currentSchemaVersion,
              decoded.enrolledAt <= now else {
            return (Record(enrolledAt: now), nil, true)
        }
        return (decoded, json, false)
    }
}
