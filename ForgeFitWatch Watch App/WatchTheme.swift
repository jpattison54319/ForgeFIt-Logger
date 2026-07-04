import SwiftUI

/// Watch-sized slice of the ForgeFit design language: same sage / mint /
/// gold family as the phone, tuned for small OLED screens.
enum WTheme {
    static let accent = Color(red: 85 / 255, green: 179 / 255, blue: 116 / 255)       // 0x55B374 Active Sage
    static let teal = Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)          // 0x34D399 Fresh Mint
    static let gold = Color(red: 245 / 255, green: 185 / 255, blue: 58 / 255)          // 0xF5B93A
    static let danger = Color(red: 255 / 255, green: 90 / 255, blue: 110 / 255)
    static let success = Color(red: 53 / 255, green: 208 / 255, blue: 122 / 255)        // 0x35D07A aligned with phone
    static let surface = Color(red: 24 / 255, green: 27 / 255, blue: 33 / 255)         // 0x181B21 neutral slate

    static func readinessColor(_ score: Int) -> Color {
        switch score {
        case ..<40: danger
        case ..<70: gold
        default: success
        }
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
}
