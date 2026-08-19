import ForgeCore
import SwiftUI

/// SwiftUI adapter for the portable theme catalog shared by widgets and Live
/// Activities. Constructed once per rendered entry/state, never per token.
struct ForgeWidgetTheme {
    let background: Color
    let accent: Color
    let accentForeground: Color
    let onAccent: Color
    let secondaryAccent: Color
    let warmup: Color
    let danger: Color
    let recoveryHigh: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    init(preference: ForgeThemePreference, systemColorScheme: ColorScheme) {
        self.init(
            family: preference.family,
            mode: preference.mode,
            systemColorScheme: systemColorScheme
        )
    }

    init(
        family: ThemeFamily,
        mode: ForgeThemeMode,
        systemColorScheme: ColorScheme
    ) {
        let appearance: ForgeThemeAppearance = switch mode {
        case .system: systemColorScheme == .dark ? .dark : .light
        case .light: .light
        case .dark: .dark
        }
        let palette = ForgeThemeCatalog.palette(for: family, appearance: appearance)
        background = Color(themeHex: palette.background)
        accent = Color(themeHex: palette.accent)
        accentForeground = Color(themeHex: palette.accentForeground)
        onAccent = Color(themeHex: palette.onAccent)
        secondaryAccent = Color(themeHex: palette.secondaryAccent)
        warmup = Color(themeHex: palette.warmup)
        danger = Color(themeHex: palette.danger)
        recoveryHigh = Color(themeHex: palette.recoveryHigh)
        textPrimary = Color(themeHex: palette.textPrimary)
        textSecondary = Color(themeHex: palette.textSecondary)
        textTertiary = Color(themeHex: palette.textTertiary)
    }

    func icon(for mode: WorkoutActivityAttributes.WorkoutActivityMode) -> String {
        switch mode {
        case .strength: "dumbbell.fill"
        case .cardio: "figure.run"
        case .conditioning: "figure.cross.training"
        case .yoga: "figure.yoga"
        }
    }
}

extension Color {
    init(themeHex: UInt32) {
        self.init(
            .sRGB,
            red: Double((themeHex >> 16) & 0xFF) / 255,
            green: Double((themeHex >> 8) & 0xFF) / 255,
            blue: Double(themeHex & 0xFF) / 255
        )
    }
}
