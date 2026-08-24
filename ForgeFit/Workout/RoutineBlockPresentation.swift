import ForgeCore
import ForgeData
import Foundation

enum ConditioningPlanPresentation {
    static let fallbackTitle = "Conditioning"

    /// A one-section conditioning block is one named effort to the athlete, so
    /// every live and historical surface should carry that name. Multi-section
    /// and unnamed legacy plans retain the familiar generic label.
    static func title(for plan: ConditioningPlan?) -> String {
        guard let plan, plan.sections.count == 1 else { return fallbackTitle }
        let name = plan.sections[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallbackTitle : name
    }

    static func accessibilityLabel(for plan: ConditioningPlan?) -> String {
        let title = title(for: plan)
        return title == fallbackTitle ? "Conditioning block" : "\(title) conditioning block"
    }
}

enum RoutineBlockPresentation {
    static func title(for block: RoutineBlockModel) -> String {
        guard block.kind == .conditioning,
              let plan = ConditioningPlan.decode(from: block.planJSON) else {
            return block.kind.title
        }
        return ConditioningPlanPresentation.title(for: plan)
    }
}
