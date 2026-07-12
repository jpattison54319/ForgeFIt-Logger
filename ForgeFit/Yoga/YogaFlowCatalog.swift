import Foundation
import ForgeCore

/// One row of the bundled `yoga_flows.json` — ForgeFit's authored guided
/// classes. Catalog-only: built-in flows are never seeded as models; attaching
/// one to a routine (or starting it) value-copies its `YogaFlowPlan` JSON,
/// matching interval-plan snapshot semantics.
struct YogaFlowSeed: Decodable {
    struct Step: Decodable {
        let poseSlug: String
        let holdSeconds: Int
        let side: String?
    }

    let slug: String
    let name: String
    let styleRaw: String
    let description: String
    let steps: [Step]

    var style: YogaStyle { YogaStyle(rawValue: styleRaw) ?? .hatha }
}

enum YogaFlowCatalog {
    private static var cached: [YogaFlowSeed]?

    static func load() -> [YogaFlowSeed] {
        if let cached { return cached }
        guard let url = Bundle.main.url(forResource: "yoga_flows", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([YogaFlowSeed].self, from: data) else {
            cached = []
            return []
        }
        cached = decoded
        return decoded
    }

    static func flow(forSlug slug: String) -> YogaFlowSeed? {
        load().first { $0.slug == slug }
    }

    /// Materialize a catalog flow into the runnable plan. Steps whose pose
    /// slug doesn't resolve are dropped (never expected — the catalog test
    /// guards it — but a stale bundle must not crash the player).
    static func plan(for seed: YogaFlowSeed) -> YogaFlowPlan {
        let steps: [YogaFlowPlan.PoseStep] = seed.steps.compactMap { step in
            guard let pose = YogaPoseCatalog.pose(forSlug: step.poseSlug) else { return nil }
            return YogaFlowPlan.PoseStep(
                poseID: YogaPoseCatalog.id(forSlug: step.poseSlug),
                poseSlug: step.poseSlug,
                name: pose.name,
                holdSeconds: step.holdSeconds,
                side: step.side.flatMap(YogaFlowPlan.Side.init(rawValue:))
            )
        }
        return YogaFlowPlan(styleRaw: seed.styleRaw, steps: steps)
    }
}
