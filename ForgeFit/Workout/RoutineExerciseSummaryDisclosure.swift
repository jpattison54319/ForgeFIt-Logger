import ForgeData
import SwiftUI

/// Compact, temporary disclosure for a routine's ordered contents. The third
/// exercise fades at the preview boundary, while blocks retain their real
/// position relative to the exercises around them.
struct RoutineExerciseSummaryDisclosure: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let routineName: String
    let items: [OrderedRoutineItem]
    let exerciseNameByID: [UUID: String]
    let isExpanded: Bool
    let onToggle: () -> Void

    /// Leaves only enough visible space for the chevron while its full tap
    /// target overlaps the non-interactive summary above it.
    private let disclosureFooterHeight: CGFloat = 14

    private var thirdExerciseIndex: Int? {
        var exerciseCount = 0
        for (index, item) in items.enumerated() {
            guard case .exercise = item else { continue }
            exerciseCount += 1
            if exerciseCount == 3 { return index }
        }
        return nil
    }

    var body: some View {
        let thirdExerciseIndex = self.thirdExerciseIndex
        let visibleItems = visibleItems(through: thirdExerciseIndex)
        let fadedItemID = fadedItemID(at: thirdExerciseIndex)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(visibleItems) { item in
                itemRow(item)
                    .mask {
                        if item.id == fadedItemID {
                            LinearGradient(
                                colors: [.white, .white.opacity(0.55), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        } else {
                            Color.white
                        }
                    }
                    .transition(.opacity)
            }

            if thirdExerciseIndex != nil {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: disclosureFooterHeight)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if thirdExerciseIndex != nil {
                Button(action: toggle) {
                    ZStack(alignment: .bottom) {
                        Color.clear
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(isExpanded ? theme.accent : theme.textTertiary)
                            .padding(.bottom, 4)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isExpanded
                        ? "Show fewer exercises in \(routineName)"
                        : "Show all exercises in \(routineName)"
                )
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("routine-exercise-disclosure-\(routineName)")
            }
        }
    }

    private func itemRow(_ item: OrderedRoutineItem) -> some View {
        let name = itemName(item)
        return HStack(spacing: 6) {
            Circle()
                .fill(theme.textTertiary)
                .frame(width: 4, height: 4)
            Text(name)
                .font(.system(size: 14))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("routine-summary-item-\(routineName)-\(name)")
        }
    }

    private func visibleItems(through thirdExerciseIndex: Int?) -> ArraySlice<OrderedRoutineItem> {
        guard !isExpanded, let thirdExerciseIndex else { return items[...] }
        return items.prefix(through: thirdExerciseIndex)
    }

    private func fadedItemID(at thirdExerciseIndex: Int?) -> UUID? {
        guard !isExpanded, let thirdExerciseIndex else { return nil }
        return items[thirdExerciseIndex].id
    }

    private func itemName(_ item: OrderedRoutineItem) -> String {
        switch item {
        case .exercise(let exercise):
            exerciseNameByID[exercise.exerciseID] ?? "Exercise"
        case .block(let block):
            RoutineBlockPresentation.title(for: block)
        }
    }

    private func toggle() {
        if reduceMotion {
            onToggle()
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                onToggle()
            }
        }
    }
}
