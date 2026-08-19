import Foundation
import ForgeCore

/// A coarse body position used to reason about transitions between poses.
/// This is intentionally simpler than anatomy: it answers only whether the
/// next instruction needs to bring someone to standing, hands-and-knees,
/// prone, seated, or supine before describing the pose itself.
enum YogaMovementBase: String, Decodable, CaseIterable, Sendable {
    case standing
    case kneeling
    case prone
    case seated
    case supine
}

/// Source-reviewed, narration-ready guidance for one bundled pose. Pose
/// identity and search metadata remain in `yoga_poses.json`; this separate
/// content file can be audited and revised without changing saved plans.
struct YogaPoseGuidance: Decodable, Sendable {
    struct Cues: Decodable, Sendable {
        let entry: [String]
        let alignment: [String]
        let breath: [String]
        let options: [String]
        let reflection: [String]
        let exit: String

        var technique: [String] {
            entry + alignment + breath + options + [exit]
        }
    }

    struct Source: Decodable, Sendable, Hashable {
        let title: String
        let url: URL
    }

    let slug: String
    let movementBase: YogaMovementBase
    /// Optional instructor-style wording for the pose-name clip. The
    /// canonical catalog name remains unchanged for search and display.
    let nameAnnouncement: String?
    let cues: Cues
    /// Actionable cautions and alternatives, deliberately not a diagnosis or
    /// a claim that every person with a named condition must avoid the pose.
    let considerations: [String]
    let sources: [Source]
}

struct YogaGlobalGuidance: Decodable, Sendable {
    let openings: [String]
    let breath: [String]
    let awareness: [String]
    let encouragement: [String]
    let spiritual: [String]
    let closings: [String]
}

private struct YogaGuidanceLibrary: Decodable, Sendable {
    let schemaVersion: Int
    let contentVersion: String
    let reviewStatus: String
    let reviewedAt: String
    let global: YogaGlobalGuidance
    let poses: [YogaPoseGuidance]
}

/// Loads the immutable, reviewed words that can be shown or narrated during
/// a guided class. No generative model is called at runtime: Gemini is only a
/// build-time narrator of these exact transcripts.
enum YogaGuidanceCatalog {
    nonisolated static let expectedSchemaVersion = 1
    nonisolated static let safetyAcknowledgementKey = "yogaSafetyAcknowledgement.v1"
    nonisolated static let recentGuidanceKey = "yogaRecentGuidance.v1"

    private static var cached: YogaGuidanceLibrary?

    private static var library: YogaGuidanceLibrary? {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "yoga_guidance", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(YogaGuidanceLibrary.self, from: data),
              decoded.schemaVersion == expectedSchemaVersion else {
            return nil
        }
        cached = decoded
        return decoded
    }

    static var contentVersion: String { library?.contentVersion ?? "unavailable" }
    static var reviewStatus: String { library?.reviewStatus ?? "unavailable" }
    static var reviewedAt: String { library?.reviewedAt ?? "unavailable" }
    static var global: YogaGlobalGuidance? { library?.global }
    static var poses: [YogaPoseGuidance] { library?.poses ?? [] }

    private static var bySlug: [String: YogaPoseGuidance] {
        Dictionary(poses.map { ($0.slug, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func guidance(forSlug slug: String?) -> YogaPoseGuidance? {
        guard let slug else { return nil }
        return bySlug[slug]
    }

    /// The side attached to a runtime step always means the working, front,
    /// standing, bent, or threaded side named by that pose's authored cue.
    /// Keeping interpolation here prevents the unsafe old behavior where the
    /// second side was announced only as "the other side."
    static func resolved(_ template: String, side: YogaFlowPlan.Side?) -> String {
        guard let side, side != .bothSides else { return template }
        let working = side == .left ? "left" : "right"
        let opposite = side == .left ? "right" : "left"
        return template
            .replacingOccurrences(of: "{side}", with: working)
            .replacingOccurrences(of: "{oppositeSide}", with: opposite)
    }

    /// Side-neutral wording for the exercise-library detail screen. The live
    /// player always uses an explicit left or right transcript instead.
    static func resolvedForLibrary(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{side}", with: "working")
            .replacingOccurrences(of: "{oppositeSide}", with: "opposite")
    }
}

/// Bounded local history used only to vary guidance. It is reset with app
/// data, excluded from backup, and never contains workout or health metrics.
@MainActor
enum YogaGuidanceHistory {
    private struct Entry: Codable {
        let completedAt: Date
        let clipIDs: [String]
    }

    private static let maximumClasses = 5
    private static let maximumClipsPerClass = 120

    static var recentClipIDs: Set<String> {
        Set(load().flatMap(\.clipIDs))
    }

    static func record(_ clipIDs: [String], at date: Date = .now) {
        let unique = Array(Set(clipIDs)).sorted().prefix(maximumClipsPerClass)
        guard !unique.isEmpty else { return }
        var entries = load()
        entries.append(Entry(completedAt: date, clipIDs: Array(unique)))
        entries = Array(entries.suffix(maximumClasses))
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: YogaGuidanceCatalog.recentGuidanceKey)
    }

    private static func load() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: YogaGuidanceCatalog.recentGuidanceKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            return []
        }
        return entries
    }
}
