import Foundation

/// Non-health metadata shared with the widget extension so a configurable
/// control can offer the same workout choices as the app. The catalog never
/// contains workout history, HealthKit values, notes, or exercise targets.
public struct WorkoutChoiceRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let systemImageName: String

    public init(
        id: String,
        title: String,
        subtitle: String,
        systemImageName: String
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
    }
}

/// Stable, backwards-compatible identifiers for workout launch surfaces.
public enum WorkoutChoiceTarget: Equatable, Sendable {
    case next
    case empty
    case routine(UUID)
    case cardio(String)
    case yogaBuiltIn(String)
    case yogaSaved(UUID)
    case conditioningBuiltIn(String)
    case conditioningSaved(UUID)

    public init?(identifier: String) {
        if identifier == "next" {
            self = .next
        } else if identifier == "empty" {
            self = .empty
        } else if let raw = identifier.removingPrefix("routine:"),
                  let id = UUID(uuidString: raw) {
            self = .routine(id)
        } else if let raw = identifier.removingPrefix("cardio:"), !raw.isEmpty {
            self = .cardio(raw)
        } else if let raw = identifier.removingPrefix("yoga-built-in:"), !raw.isEmpty {
            self = .yogaBuiltIn(raw)
        } else if let raw = identifier.removingPrefix("yoga-saved:"),
                  let id = UUID(uuidString: raw) {
            self = .yogaSaved(id)
        } else if let raw = identifier.removingPrefix("conditioning-built-in:"), !raw.isEmpty {
            self = .conditioningBuiltIn(raw)
        } else if let raw = identifier.removingPrefix("conditioning-saved:"),
                  let id = UUID(uuidString: raw) {
            self = .conditioningSaved(id)
        } else {
            return nil
        }
    }

    public var identifier: String {
        switch self {
        case .next:
            "next"
        case .empty:
            "empty"
        case .routine(let id):
            "routine:\(id.uuidString)"
        case .cardio(let raw):
            "cardio:\(raw)"
        case .yogaBuiltIn(let slug):
            "yoga-built-in:\(slug)"
        case .yogaSaved(let id):
            "yoga-saved:\(id.uuidString)"
        case .conditioningBuiltIn(let raw):
            "conditioning-built-in:\(raw)"
        case .conditioningSaved(let id):
            "conditioning-saved:\(id.uuidString)"
        }
    }
}

public enum WorkoutChoiceCatalogStore {
    public static let suiteName = "group.org.xpetsllc.ForgeFit"
    public static let key = "appIntents.workoutChoices.v1"

    public static func load(
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    ) -> [WorkoutChoiceRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([WorkoutChoiceRecord].self, from: data) else {
            return []
        }
        return records
    }

    public static func save(
        _ records: [WorkoutChoiceRecord],
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    ) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: key)
    }

    public static func clear(
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    ) {
        defaults.removeObject(forKey: key)
    }
}

public enum ForgeFitIntentDeepLink {
    public static let resumeWorkout = URL(string: "forgefit://workout")!
    public static let startNextWorkout = URL(string: "forgefit://start-next")!
    public static let chooseWorkout = URL(string: "forgefit://choose-workout")!

    public static func startWorkout(choiceID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "forgefit"
        components.host = "start-choice"
        components.queryItems = [URLQueryItem(name: "id", value: choiceID)]
        return components.url
    }

    public static func routine(_ id: UUID) -> URL {
        URL(string: "forgefit://routine/\(id.uuidString)")!
    }

    public static func exercise(_ id: UUID) -> URL {
        URL(string: "forgefit://exercise/\(id.uuidString)")!
    }
}

/// Immediate Watch intent replies. These travel only over `sendMessage`; they
/// are never queued, so a disconnected phone cannot start a surprise workout
/// later after reachability returns.
public enum WatchImmediateStartResult: Codable, Equatable, Sendable {
    case started(title: String)
    case activeWorkout(title: String)
    case chooseWorkout(message: String)
    case unavailable(message: String)
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
