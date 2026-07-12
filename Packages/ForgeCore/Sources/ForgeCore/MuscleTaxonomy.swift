import Foundation

/// The muscle-group taxonomy: broad parent groups (Shoulders, Back, Chest)
/// with drill-down sub-muscles, plus normalization of the legacy string
/// variants that live in seeded and imported exercises ("front_delts",
/// "mid_back", "cardiorespiratory"...).
///
/// Muscles are stored on exercises as plain strings, so the hierarchy is a
/// lookup layer, not a data migration: exercises tagged with a parent
/// ("shoulders") or a child ("rear delts") are both valid forever, and
/// analytics roll variants together through `canonical(_:)`.
public enum MuscleTaxonomy {
    /// Parent → ordered children, canonical lowercase names.
    public static let children: [String: [String]] = [
        "shoulders": ["front delts", "side delts", "rear delts"],
        "back": ["lats", "upper back", "middle back", "lower back", "traps"],
        "chest": ["upper chest", "mid chest", "lower chest"],
    ]

    /// Child → parent, derived from `children`.
    public static let parentByChild: [String: String] = {
        var map: [String: String] = [:]
        for (parent, kids) in children {
            for kid in kids { map[kid] = parent }
        }
        return map
    }()

    /// Legacy/imported spelling variants → canonical names. Seeded exercises
    /// and old imports use underscores and a few different words; analytics
    /// must not split "front_delts" and "front delts" into separate buckets.
    public static let aliases: [String: String] = [
        "front_delts": "front delts",
        "side_delts": "side delts",
        "lateral delts": "side delts",
        "lateral_delts": "side delts",
        "rear_delts": "rear delts",
        "delts": "shoulders",
        "mid_back": "middle back",
        "mid back": "middle back",
        "middle_back": "middle back",
        "upper_back": "upper back",
        "lower_back": "lower back",
        "spinal_erectors": "lower back",
        "erectors": "lower back",
        "upper_chest": "upper chest",
        "mid_chest": "mid chest",
        "middle chest": "mid chest",
        "lower_chest": "lower chest",
        "quads": "quadriceps",
        "cardiorespiratory": "cardiovascular",
        "core": "abdominals",
        "abs": "abdominals",
    ]

    /// Normalize any stored muscle string to its canonical lowercase name.
    /// Unknown strings pass through lowercased-trimmed so nothing is dropped.
    public static func canonical(_ raw: String) -> String {
        let base = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases[base] ?? base
    }

    /// The broad group a muscle belongs to: a child's parent, otherwise the
    /// muscle itself (top-level groups like "biceps" are their own parent).
    public static func parent(of muscle: String) -> String {
        let name = canonical(muscle)
        return parentByChild[name] ?? name
    }

    /// True when `muscle` belongs under `group` — an exact (canonical) match,
    /// or a child of the group. Lets a "Shoulders" filter find exercises
    /// tagged "rear delts".
    public static func matches(_ muscle: String, group: String) -> Bool {
        let m = canonical(muscle)
        let g = canonical(group)
        return m == g || parentByChild[m] == g
    }

    /// "front delts" → "Front Delts", "upper back" → "Upper Back".
    public static func displayName(_ muscle: String) -> String {
        canonical(muscle).split(separator: " ").map(\.capitalized).joined(separator: " ")
    }
}
