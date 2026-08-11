import SwiftUI

struct MyoRepMiniSetCard: View {
    @Environment(\.theme) private var theme
    let side: Int
    let loggedReps: [Int]
    let plannedCount: Int?
    @Binding var repsDraft: Int
    let focus: FocusState<MyoRepInputFocus?>.Binding
    let onSubmit: () -> Void
    let onLog: () -> Void
    let onEdit: (Int) -> Void

    var body: some View {
        Card(padding: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Mini-sets")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text(progressLabel)
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Text("Side \(side)")
                        .font(.tag)
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.4)))
                }

                if !loggedReps.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.sm) {
                            ForEach(Array(loggedReps.enumerated()), id: \.offset) { index, reps in
                                MyoRepMiniSetCircle(side: side, index: index, reps: reps) {
                                    onEdit(index)
                                }
                            }
                        }
                    }
                }

                Divider().overlay(theme.separator)

                MyoRepIntegerStepper(
                    value: $repsDraft,
                    label: "Next mini-set reps",
                    focus: focus,
                    focusValue: .activeMini(side: side),
                    onSubmit: onSubmit,
                    accessibilityIdentifier: "myo-mini-reps-\(side)"
                )

                SecondaryButton(
                    title: "Log \(repsDraft) Reps",
                    systemImage: "plus",
                    action: onLog
                )
                .accessibilityIdentifier("myo-log-mini-\(side)")
            }
        }
    }

    private var progressLabel: String {
        guard let plannedCount, plannedCount > 0 else {
            return "\(loggedReps.count) logged"
        }
        return "\(loggedReps.count) of \(plannedCount) planned"
    }
}
