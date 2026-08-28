import Foundation

public struct WorkoutIntentDiagnosticSnapshot: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case queryMatched
        case queryAmbiguous
        case queryNoMatch
        case namedWorkout
        case nextWorkout
        case nextFallback
        case emptyWorkout
        case unavailable
    }

    public let updatedAt: Date
    public let queryText: String?
    public let candidateTitles: [String]
    public let selectedTitle: String?
    public let selectedIdentifier: String?
    public let outcome: Outcome

    public init(
        updatedAt: Date,
        queryText: String?,
        candidateTitles: [String],
        selectedTitle: String?,
        selectedIdentifier: String?,
        outcome: Outcome
    ) {
        self.updatedAt = updatedAt
        self.queryText = queryText
        self.candidateTitles = candidateTitles
        self.selectedTitle = selectedTitle
        self.selectedIdentifier = selectedIdentifier
        self.outcome = outcome
    }
}

/// Stores one small, local diagnostic for the modern App Intents path. The
/// string is the entity-query text supplied by the system, not audio and not a
/// complete Siri transcript. A new query replaces the previous one, and a
/// reset or visible Clear action removes it.
public actor WorkoutIntentDiagnosticStore {
    public static let shared = WorkoutIntentDiagnosticStore()
    public static let key = "appIntents.lastWorkoutDiagnostic.v1"

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    public init(
        suiteName: String = WorkoutChoiceCatalogStore.suiteName,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.now = now
    }

    public func snapshot() -> WorkoutIntentDiagnosticSnapshot? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(
            WorkoutIntentDiagnosticSnapshot.self,
            from: data
        )
    }

    public func recordQuery(
        _ text: String,
        matches: [WorkoutChoiceNameMatch]
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let outcome: WorkoutIntentDiagnosticSnapshot.Outcome = switch matches.count {
        case 0: .queryNoMatch
        case 1: .queryMatched
        default: .queryAmbiguous
        }
        save(WorkoutIntentDiagnosticSnapshot(
            updatedAt: now(),
            queryText: trimmed,
            candidateTitles: Array(matches.prefix(5).map(\.record.title)),
            selectedTitle: matches.count == 1 ? matches[0].record.title : nil,
            selectedIdentifier: matches.count == 1 ? matches[0].record.id : nil,
            outcome: outcome
        ))
    }

    public func recordExecution(
        selected: WorkoutChoiceRecord?,
        outcome: WorkoutIntentDiagnosticSnapshot.Outcome
    ) {
        let timestamp = now()
        let previous = snapshot()
        // Query and execution are normally adjacent. Do not attach an old
        // Shortcuts search to a later identifier-based invocation.
        let recentQuery = previous.flatMap {
            timestamp.timeIntervalSince($0.updatedAt) <= 120 ? $0 : nil
        }
        save(WorkoutIntentDiagnosticSnapshot(
            updatedAt: timestamp,
            queryText: recentQuery?.queryText,
            candidateTitles: recentQuery?.candidateTitles ?? [],
            selectedTitle: selected?.title,
            selectedIdentifier: selected?.id,
            outcome: outcome
        ))
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    private func save(_ snapshot: WorkoutIntentDiagnosticSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
