import SwiftUI

// MARK: - Theme

/// Sage color scheme — slate obsidian canvas with neutral slate surfaces and
/// an Active Sage / Fresh Mint accent duotone. Expressed as a value type so the
/// active theme can be injected via the SwiftUI environment and swapped at
/// runtime in a future update.
struct AppTheme {

    // Canvas & surfaces
    let background: Color
    let surface: Color
    let surfaceElevated: Color
    let surfaceHighlight: Color
    let separator: Color

    // Brand — Active Sage primary, Fresh Mint secondary
    let accent: Color
    let accentSoft: Color
    let secondaryAccent: Color
    let warmup: Color
    let success: Color
    let danger: Color

    // Recovery / readiness scale (coral -> amber -> emerald)
    let recoveryLow: Color
    let recoveryMid: Color
    let recoveryHigh: Color

    // Cardio heart-rate zones (1->5)
    let zone1: Color
    let zone2: Color
    let zone3: Color
    let zone4: Color
    let zone5: Color

    // Sticky-note (exercise notes)
    let stickyFill: Color
    let stickyInk: Color

    // Text (green-tinted grays)
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color

    func zoneColor(_ zone: Int) -> Color {
        switch zone {
        case 1: return zone1
        case 2: return zone2
        case 3: return zone3
        case 4: return zone4
        default: return zone5
        }
    }

    /// Map a 0...1 readiness score onto the recovery gradient stops.
    func readinessColor(_ score: Double) -> Color {
        switch score {
        case ..<0.4: return recoveryLow
        case ..<0.7: return recoveryMid
        default: return recoveryHigh
        }
    }
}

// MARK: - Sage (default theme: dark + light variants)

extension AppTheme {
    /// The original Sage look — slate obsidian canvas, Active Sage / Fresh
    /// Mint accent duotone. `.sage` is kept as an alias so existing call
    /// sites that want a theme-independent fixed reference (badge colors,
    /// share-card rendering, tests) keep their exact current look.
    static let sageDark = AppTheme(
        background: Color(hex: 0x0E1116),
        surface: Color(hex: 0x181B21),
        surfaceElevated: Color(hex: 0x20242B),
        surfaceHighlight: Color(hex: 0x282D35),
        separator: Color(hex: 0x333942),
        accent: Color(hex: 0x55B374),
        accentSoft: Color(hex: 0x55B374).opacity(0.18),
        secondaryAccent: Color(hex: 0x34D399),
        warmup: Color(hex: 0xF5B93A),
        success: Color(hex: 0x35D07A),
        danger: Color(hex: 0xFF5A6E),
        recoveryLow: Color(hex: 0xFF5A6E),
        recoveryMid: Color(hex: 0xF5B93A),
        recoveryHigh: Color(hex: 0x35D07A),
        zone1: Color(hex: 0x8E8B99),
        zone2: Color(hex: 0x2AD4C6),
        zone3: Color(hex: 0xF5C518),
        zone4: Color(hex: 0xFF9F0A),
        zone5: Color(hex: 0xFF5A6E),
        stickyFill: Color(hex: 0xF6D66B),
        stickyInk: Color(hex: 0x2A2410),
        textPrimary: Color(hex: 0xFFFFFF),
        textSecondary: Color(hex: 0xA4ABA6),
        textTertiary: Color(hex: 0x747A74)
    )

    static let sage = sageDark

    /// Same Sage/Mint brand hues, tuned for a light canvas: signal colors are
    /// deepened so they clear ~4.5:1 contrast against white/near-white
    /// surfaces (the dark-mode values are pale enough to read fine on a
    /// near-black canvas but wash out on white). Sticky-note colors are
    /// intentionally unchanged — they represent a fixed "paper" surface, not
    /// part of the app chrome.
    static let sageLight = AppTheme(
        background: Color(hex: 0xF3F5F1),
        surface: Color(hex: 0xFFFFFF),
        surfaceElevated: Color(hex: 0xFFFFFF),
        surfaceHighlight: Color(hex: 0xE8F3EA),
        separator: Color(hex: 0xDEE3DE),
        accent: Color(hex: 0x2F9E58),
        accentSoft: Color(hex: 0x2F9E58).opacity(0.14),
        secondaryAccent: Color(hex: 0x159873),
        warmup: Color(hex: 0xB8790A),
        success: Color(hex: 0x1E9A55),
        danger: Color(hex: 0xE0334C),
        recoveryLow: Color(hex: 0xE0334C),
        recoveryMid: Color(hex: 0xB8790A),
        recoveryHigh: Color(hex: 0x1E9A55),
        zone1: Color(hex: 0x6B6876),
        zone2: Color(hex: 0x0E9A8E),
        zone3: Color(hex: 0x9A7D00),
        zone4: Color(hex: 0xC97400),
        zone5: Color(hex: 0xE0334C),
        stickyFill: Color(hex: 0xF6D66B),
        stickyInk: Color(hex: 0x2A2410),
        textPrimary: Color(hex: 0x14171A),
        textSecondary: Color(hex: 0x50594F),
        textTertiary: Color(hex: 0x82897F)
    )

    /// Resolves which variant is active for a chosen `ThemeMode` + the
    /// device's live system appearance.
    static func active(for mode: ThemeMode, system: ColorScheme) -> AppTheme {
        mode.resolvedColorScheme(system: system) == .dark ? .sageDark : .sageLight
    }
}

// MARK: - Appearance mode

/// The user's chosen appearance. `.system` tracks the device's live
/// light/dark setting; `.light`/`.dark` pin the app regardless of the
/// device setting. Persisted via `ThemeManager`, surfaced in Settings.
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    func resolvedColorScheme(system: ColorScheme) -> ColorScheme {
        switch self {
        case .system: system
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: AppTheme = .sageDark
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Radii & spacing

enum Radius {
    static let card: CGFloat = 16
    static let control: CGFloat = 12
    static let pill: CGFloat = 999
    static let tag: CGFloat = 8
}

enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    /// Bottom inset to keep content clear of the floating tab bar.
    static let tabBarClearance: CGFloat = 96
}

// MARK: - Typography

extension Font {
    static let screenTitle = Font.system(size: 34, weight: .bold, design: .default)
    static let sectionTitle = Font.system(size: 22, weight: .bold)
    static let cardTitle = Font.system(size: 20, weight: .semibold)
    static let metricValue = Font.system(size: 30, weight: .bold)
    static let statValue = Font.system(size: 22, weight: .semibold)
    static let bodyStrong = Font.system(size: 16, weight: .semibold)
    static let rowValue = Font.system(size: 17, weight: .semibold)
    static let label = Font.system(size: 13, weight: .medium)
    static let tag = Font.system(size: 12, weight: .semibold)
}

// MARK: - Color hex helper

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
