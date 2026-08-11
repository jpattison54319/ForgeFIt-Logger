import SwiftUI

struct MyoRepMiniSetCircle: View {
    @Environment(\.theme) private var theme
    let side: Int
    let index: Int
    let reps: Int
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            Text("+\(reps)")
                .font(.bodyStrong)
                .monospacedDigit()
                .foregroundStyle(theme.accent)
                .frame(width: 50, height: 50)
                .background(theme.accentSoft)
                .clipShape(.circle)
                .overlay {
                    Circle().strokeBorder(theme.accent.opacity(0.45))
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 20, height: 20)
                        .background(theme.surfaceElevated)
                        .clipShape(.circle)
                        .overlay {
                            Circle().strokeBorder(theme.separator)
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 52, minHeight: 52)
        .accessibilityLabel("Edit mini-set \(index + 1)")
        .accessibilityValue("\(reps) reps")
        .accessibilityIdentifier("myo-edit-mini-\(side)-\(index + 1)")
    }
}
