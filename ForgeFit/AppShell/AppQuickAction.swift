import Foundation

/// One action in the floating quick-action bubble (the fan that morphs out of
/// the trigger above the tab bar). Deliberately separate from Home's
/// quick-start row: same string-id wire format, but its own type, key, and
/// pool — `TrainingFocus.quickStartIDs` seeds only Home, never this.
struct AppQuickAction: Hashable, Identifiable {
    enum Kind: Hashable {
        case emptyWorkout
        case logBodyweight
        case cardio(CardioModality)
        case routine(UUID)
        /// A built-in guided yoga class, keyed by its catalog flow slug.
        case yoga(String)
    }

    var kind: Kind

    /// Stable persisted identity. The prefix format matches Home's quick-start
    /// wire shape so both preferences read alike in a backup.
    var id: String {
        switch kind {
        case .emptyWorkout: "empty"
        case .logBodyweight: "bodyweight"
        case .cardio(let modality): "cardio:\(modality.rawValue)"
        case .routine(let id): "routine:\(id.uuidString)"
        case .yoga(let slug): "yoga:\(slug)"
        }
    }

    init(kind: Kind) {
        self.kind = kind
    }

    /// Parse a persisted id. Unknown ids return nil and are DROPPED by the
    /// store — an id written by a newer app version must not decode into a
    /// duplicate fallback action.
    init?(id raw: String) {
        if raw == "empty" {
            kind = .emptyWorkout
        } else if raw == "bodyweight" {
            kind = .logBodyweight
        } else if let modalityRaw = raw.removingPrefix("cardio:"),
                  let modality = CardioModality(rawValue: modalityRaw) {
            kind = .cardio(modality)
        } else if let idRaw = raw.removingPrefix("routine:"),
                  let id = UUID(uuidString: idRaw) {
            kind = .routine(id)
        } else if let slug = raw.removingPrefix("yoga:"), !slug.isEmpty {
            kind = .yoga(slug)
        } else {
            return nil
        }
    }

    static let emptyWorkout = AppQuickAction(kind: .emptyWorkout)
    static let logBodyweight = AppQuickAction(kind: .logBodyweight)

    static func cardio(_ modality: CardioModality) -> AppQuickAction {
        AppQuickAction(kind: .cardio(modality))
    }

    static func routine(_ id: UUID) -> AppQuickAction {
        AppQuickAction(kind: .routine(id))
    }

    static func yoga(_ slug: String) -> AppQuickAction {
        AppQuickAction(kind: .yoga(slug))
    }

    /// Catalog-independent glyph; the view layer refines yoga to the flow's
    /// style glyph when the catalog resolves.
    var systemImage: String {
        switch kind {
        case .emptyWorkout: "square.and.pencil"
        case .logBodyweight: "scalemass.fill"
        case .cardio(let modality): modality.systemImage
        case .routine: "list.bullet.clipboard"
        case .yoga: "figure.yoga"
        }
    }

    /// Title when the target can't be resolved (or needs none); the view layer
    /// substitutes live routine and yoga-flow names.
    var fallbackTitle: String {
        switch kind {
        case .emptyWorkout: "Empty workout"
        case .logBodyweight: "Log weight"
        case .cardio(let modality): modality.title
        case .routine: "Routine"
        case .yoga: "Yoga"
        }
    }
}

/// Persistence for the bubble's action list: a JSON array of action ids stored
/// as a STRING (not Data) in standard `UserDefaults`, so UI tests can seed it
/// via a `-quickActionBubble.v1 <json>` launch argument. NOTE: the dotted key
/// defeats UserDefaults KVO (dots read as key-path separators), so @AppStorage
/// can NOT live-observe writes made through this store — readers refresh via
/// an explicit reload token instead (see QuickActionsBubble). The key is
/// registered in `AppPreferenceKeys.backedUp` — a training preference (ids
/// only, no health data), so it rides the iCloud backup and is cleared on
/// reset.
enum AppQuickActionStore {
    static let key = "quickActionBubble.v1"
    /// Fan budget: 5×44pt bubbles + 5×32pt labeled gaps + the 52pt trigger
    /// ≈ 432pt of vertical fan — fits above the tab bar on every supported
    /// device.
    static let maxCount = 5
    static let defaultActions: [AppQuickAction] = [.emptyWorkout, .logBodyweight, .cardio(.run)]

    static func decodeList(from json: String) -> [AppQuickAction] {
        guard let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        let actions = ids
            .compactMap(AppQuickAction.init(id:))
            .filter { seen.insert($0.id).inserted }
        return Array(actions.prefix(maxCount))
    }

    static func encodeList(_ actions: [AppQuickAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions.map(\.id)),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    static func load(defaults: UserDefaults = .standard) -> [AppQuickAction] {
        let decoded = decodeList(from: defaults.string(forKey: key) ?? "")
        return decoded.isEmpty ? defaultActions : decoded
    }

    static func save(_ actions: [AppQuickAction], defaults: UserDefaults = .standard) {
        defaults.set(encodeList(actions), forKey: key)
    }

    /// Drop actions whose target no longer exists (deleted routine, retired
    /// catalog flow). Pure so tests don't need a model container.
    static func filterDangling(
        _ actions: [AppQuickAction],
        validRoutineIDs: Set<UUID>,
        validYogaSlugs: Set<String>
    ) -> [AppQuickAction] {
        actions.filter { action in
            switch action.kind {
            case .emptyWorkout, .logBodyweight, .cardio: true
            case .routine(let id): validRoutineIDs.contains(id)
            case .yoga(let slug): validYogaSlugs.contains(slug)
            }
        }
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
