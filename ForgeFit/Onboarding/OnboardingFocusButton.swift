import SwiftUI

struct OnboardingFocusButton: View {
    @Environment(\.theme) private var theme
    let option: TrainingFocus
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: Space.sm) {
                    Image(systemName: option.systemImage)
                        .font(.cardTitle)
                    Text(option.title)
                        .font(.bodyStrong)
                }
                .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 76)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.accent)
                        .padding(Space.sm)
                        .accessibilityHidden(true)
                }
            }
            .background(isSelected ? theme.accent.opacity(0.14) : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .animation(Motion.tap, value: isSelected)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(option.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("onboarding-focus-\(option.rawValue)")
    }
}
