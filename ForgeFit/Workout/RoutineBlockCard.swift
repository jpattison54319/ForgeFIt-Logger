import ForgeCore
import ForgeData
import SwiftUI

struct RoutineBlockCard: View {
    @Environment(\.theme) private var theme

    let block: RoutineBlockModel
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onReorderDragChanged: (CGFloat) -> Void
    let onReorderDragEnded: () -> Void
    let onAccessibilityMoveBy: (Int) -> Void

    private var tint: Color { block.kind == .conditioning ? theme.warmup : theme.accent }

    var body: some View {
        Card(padding: Space.md) {
            HStack(spacing: Space.md) {
                Image(systemName: block.kind == .conditioning ? "stopwatch" : "figure.yoga")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(theme.surfaceElevated)
                    .clipShape(.circle)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(RoutineBlockPresentation.title(for: block))
                        .font(.cardTitle)
                        .foregroundStyle(theme.textPrimary)
                    Text(summary)
                        .font(.label)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Space.sm)

                ReorderHandle(
                    onDragChanged: onReorderDragChanged,
                    onDragEnded: onReorderDragEnded,
                    onAccessibilityMoveBy: onAccessibilityMoveBy
                )

                ScrollSafeMenu(sections: [
                    [ScrollSafeMenuItem(
                        title: "Edit Block",
                        systemImage: "slider.horizontal.3",
                        action: onEdit
                    )],
                    [ScrollSafeMenuItem(
                        title: "Remove Block",
                        systemImage: "trash",
                        isDestructive: true,
                        action: onRemove
                    )]
                ]) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Block options")
                .accessibilityIdentifier("routine-block-options-\(block.id.uuidString)")
            }
        }
        .accessibilityIdentifier("routine-\(block.kindRaw)-block")
    }

    private var summary: String {
        switch block.kind {
        case .conditioning:
            guard let plan = ConditioningPlan.decode(from: block.planJSON) else { return "Configure block" }
            let movements = Set(plan.sections.flatMap(\.movements).map(\.exerciseID)).count
            let sections = plan.sections.count
            return "\(sections) section\(sections == 1 ? "" : "s") · \(movements) movement\(movements == 1 ? "" : "s")"
        case .yoga:
            guard let plan = YogaFlowPlan.decode(from: block.planJSON), plan.hasSteps else { return "Configure flow" }
            return "\(plan.structureSummary) · \(plan.style.title)"
        }
    }
}
