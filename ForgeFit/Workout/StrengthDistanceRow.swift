import ForgeCore
import SwiftUI

struct StrengthDistanceRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var distanceToken = UUID()
    @State private var focusRequest = 0

    let setID: UUID
    let number: Int
    let meters: Double?
    let weight: Double?
    let showsLoad: Bool
    let weightUnit: WeightUnit
    let supportsResistanceBands: Bool
    let completed: Bool
    let pendingDrafts: PendingDraftCoordinator
    let onDistance: (Double?) -> Void
    let onLoad: (Double?) -> Void
    var onToggleCompletion: (() -> Bool)?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Divider().overlay(theme.separator)
            HStack {
                Text("Set \(number)")
                    .font(.bodyStrong)
                    .foregroundStyle(completed ? theme.success : theme.textPrimary)
                Spacer()
                ScrollSafeMenu(sections: [[
                    ScrollSafeMenuItem(title: "Delete Set", systemImage: "trash", isDestructive: true, action: onDelete)
                ]]) {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Distance set options")
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Space.sm))
                : AnyLayout(HStackLayout(spacing: Space.sm))
            layout {
                if showsLoad {
                    StrengthSetLoadField(
                        weight: weight, unit: weightUnit, supportsResistanceBands: supportsResistanceBands,
                        pendingDrafts: pendingDrafts, setID: setID, onSave: onLoad
                    )
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 134)
                }
                StrengthDistanceField(
                    meters: meters, token: distanceToken, focusRequest: focusRequest,
                    isEditable: !completed, pendingDrafts: pendingDrafts, onSave: onDistance
                )
                if let onToggleCompletion {
                    Button {
                        pendingDrafts.commit(setID)
                        pendingDrafts.commit(distanceToken)
                        if onToggleCompletion() { hideKeyboard() } else { focusRequest += 1 }
                    } label: {
                        Label(completed ? "Reopen Set" : "Complete Set",
                              systemImage: completed ? "checkmark.circle.fill" : "checkmark.circle")
                            .labelStyle(.iconOnly)
                            .font(.sectionTitle)
                            .foregroundStyle(completed ? theme.success : theme.accentForeground)
                            .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                            .contentShape(.rect)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityIdentifier(completed ? "reopen-distance-set" : "complete-distance-set")
                }
            }
        }
        .padding(.bottom, Space.xs)
        .sensoryFeedback(.success, trigger: completed) { _, completed in completed }
    }
}
