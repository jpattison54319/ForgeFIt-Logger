import ForgeCore
import SwiftUI

struct MicrocycleHistoryRoutineCard: View {
    @Environment(\.theme) private var theme

    let progress: MicrocycleProgress

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Workouts")
                .font(.sectionTitle)
                .foregroundStyle(theme.textPrimary)

            Card {
                VStack(spacing: Space.md) {
                    let markers = MicrocycleRoutineMarker.markersByRoutineID(
                        in: progress.routines.map(\.routine)
                    )
                    ForEach(progress.routines) { item in
                        HStack(spacing: Space.sm) {
                            MicrocycleRoutineStatusMarker(
                                marker: markers[item.routine.id] ?? "?",
                                isCompleted: item.isCompleted
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completedName(for: item))
                                    .font(.body)
                                    .foregroundStyle(
                                        item.isCompleted ? theme.textSecondary : theme.textPrimary
                                    )
                                    .lineLimit(1)
                                Text(completionText(for: item))
                                    .font(.subheadline)
                                    .foregroundStyle(theme.textTertiary)
                            }
                            Spacer(minLength: Space.sm)
                            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(
                                    item.isCompleted ? theme.accent : theme.textTertiary
                                )
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: TouchTarget.minimum)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private func completedName(for item: MicrocycleRoutineProgress) -> String {
        guard let completedID = item.completedRoutineID else { return item.routine.name }
        return item.routine.memberName(for: completedID) ?? item.routine.name
    }

    private func completionText(for item: MicrocycleRoutineProgress) -> String {
        if let completedAt = item.completedAt {
            return "Completed \(completedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Not completed"
    }
}
