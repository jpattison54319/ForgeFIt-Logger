import ForgeCore
import SwiftUI

/// Watch-sized slice of the selected ForgeFit family, tuned for OLED. The
/// palette is cached in-process and refreshed whenever a phone context lands.
@MainActor
enum WTheme {
    /// Apple's minimum comfortable touch dimension, including clear padding
    /// around compact glyphs whose visible size should stay unchanged.
    static let minimumTouchTarget: CGFloat = 44

    private(set) static var family = ForgeThemePreferenceStore.load().family

    private static var palette: ForgeThemePalette {
        ForgeThemeCatalog.palette(for: family, appearance: .dark)
    }

    static var accent: Color { Color(themeHex: palette.accent) }
    static var teal: Color { Color(themeHex: palette.secondaryAccent) }
    static var gold: Color { Color(themeHex: palette.warmup) }
    static var danger: Color { Color(themeHex: palette.danger) }
    static var success: Color { Color(themeHex: palette.success) }
    static var surface: Color { Color(themeHex: palette.surface) }

    static func configure(family: ThemeFamily) {
        self.family = family
    }

    static func readinessColor(_ score: Int) -> Color {
        switch score {
        case ..<40: danger
        case ..<70: gold
        default: success
        }
    }
}

private extension Color {
    init(themeHex: UInt32) {
        self.init(
            .sRGB,
            red: Double((themeHex >> 16) & 0xFF) / 255,
            green: Double((themeHex >> 8) & 0xFF) / 255,
            blue: Double(themeHex & 0xFF) / 255
        )
    }
}

enum WFmt {
    /// "12:34" / "1:02:09" elapsed clock.
    static func elapsed(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "0:45" rest countdown.
    static func rest(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// Weight as entered — display units, never converted (app-wide rule).
    static func weight(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value == value.rounded()
            ? String(Int(value))
            : value.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Live distance in the user's unit (from the synced `WatchAppContext`).
    static func distance(_ meters: Double?, unit: DistanceUnit) -> String {
        guard let meters else { return "—" }
        return "\(unit.distance(fromMeters: meters).formatted(.number.precision(.fractionLength(0...2)))) \(unit.abbreviation)"
    }
}
