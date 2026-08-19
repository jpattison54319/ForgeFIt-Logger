import ForgeCore
import ForgeData
import Foundation

enum RoutineBlockPresentation {
    static func title(for block: RoutineBlockModel) -> String {
        guard block.kind == .conditioning,
              let plan = ConditioningPlan.decode(from: block.planJSON),
              plan.sections.count == 1 else {
            return block.kind.title
        }

        let name = plan.sections[0].name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? block.kind.title : name
    }
}
