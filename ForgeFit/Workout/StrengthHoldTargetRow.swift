import ForgeCore
import ForgeData
import SwiftUI

struct StrengthHoldTargetRow: View {
    @Environment(\.theme) private var theme
    let set: RoutineSetModel
    let number: Int
    let defaultSeconds: Int
    let showsLoad: Bool
    let unit: WeightUnit
    let supportsResistanceBands: Bool
    let pendingDrafts: PendingDraftCoordinator
    let onChange: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollSafeMenu(sections: [[
                ScrollSafeMenuItem(title: "Delete Set", systemImage: "trash", isDestructive: true, action: onDelete)
            ]]) {
                HStack(spacing: 3) {
                    Text(number.formatted()).font(.system(size: 15, weight: .bold))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                }
                .foregroundStyle(theme.textPrimary)
                .frame(width: 40, height: TouchTarget.minimum)
                .contentShape(.rect)
            }
            .accessibilityLabel("Set \(number), options")
            .accessibilityIdentifier("timed-routine-set-options")
            StrengthHoldDurationButton(
                seconds: StrengthHold.validSeconds(set.targetDurationSeconds) ?? defaultSeconds,
                identifier: "routine-set-duration",
                accessibilityTitle: "Target duration for set \(number)"
            ) {
                set.setType = .timedHold
                set.targetDurationSeconds = $0
                onChange()
            }
            if showsLoad {
                StrengthSetLoadField(
                    weight: set.loadPrescriptionMode == .fixed ? set.targetWeight : nil,
                    unit: unit,
                    supportsResistanceBands: supportsResistanceBands,
                    compact: true,
                    pendingDrafts: pendingDrafts,
                    setID: set.id
                ) {
                    set.loadPrescriptionMode = .fixed
                    set.targetWeight = $0
                    onChange()
                }
            }
        }
        .padding(6)
    }
}
