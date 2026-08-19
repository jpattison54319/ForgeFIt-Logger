import ForgeCore
import SwiftUI

struct ThemeChoiceView: View {
    @Environment(\.colorScheme) private var systemColorScheme
    @EnvironmentObject private var themeManager: ThemeManager

    let family: ThemeFamily

    private var choiceTheme: AppTheme {
        .active(
            family: family,
            mode: themeManager.mode,
            system: systemColorScheme
        )
    }

    private var isSelected: Bool {
        themeManager.family == family
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text(family.displayName)
                .font(.bodyStrong)
                .foregroundStyle(choiceTheme.textPrimary)
                .accessibilityHidden(true)

            Button(action: selectTheme) {
                DiagonalThemeSwatch(
                    primary: choiceTheme.accent,
                    accent: choiceTheme.secondaryAccent,
                    isSelected: isSelected
                )
                .aspectRatio(1.75, contentMode: .fit)
                .frame(minHeight: 56)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(family.displayName) theme")
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("theme-option-\(family.rawValue)")
        }
    }

    private func selectTheme() {
        themeManager.family = family
    }
}
