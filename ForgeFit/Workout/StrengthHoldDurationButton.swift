import ForgeCore
import SwiftUI

struct StrengthHoldDurationButton: View {
    @Environment(\.theme) private var theme
    @State private var isEditing = false

    let seconds: Int
    let identifier: String
    var height: CGFloat = TouchTarget.minimum
    var accessibilityTitle = "Duration"
    let onSave: (Int) -> Void

    var body: some View {
        Button {
            isEditing = true
        } label: {
            HStack(spacing: Space.xs) {
                Text(Fmt.elapsed(seconds))
                    .font(.bodyStrong.monospacedDigit())
                    .layoutPriority(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Space.xs)
            .foregroundStyle(theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(theme.surfaceElevated, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(Fmt.elapsed(seconds))
        .accessibilityIdentifier(identifier)
        .sheet(isPresented: $isEditing) {
            StrengthHoldDurationSheet(seconds: seconds, onSave: onSave)
                .presentationDetents([.medium, .large])
        }
    }
}
