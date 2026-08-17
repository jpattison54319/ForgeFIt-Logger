import Foundation

/// Stable identifiers for ForgeFit's approved color families. Raw values are
/// persisted and travel over WatchConnectivity, so existing cases must never
/// be renamed or reused for a different palette.
public enum ThemeFamily: String, CaseIterable, Codable, Identifiable, Sendable {
    case sage
    case rose
    case ocean
    case violet
    case ember
    case graphite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sage: "Sage"
        case .rose: "Rose"
        case .ocean: "Ocean"
        case .violet: "Violet"
        case .ember: "Ember"
        case .graphite: "Graphite"
        }
    }
}

/// The app's appearance preference. Extensions share this Foundation-only
/// representation and resolve `.system` against their own SwiftUI environment.
public enum ForgeThemeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

public enum ForgeThemeAppearance: Sendable {
    case light
    case dark
}

/// Opaque sRGB values shared by every target. Keeping palette construction out
/// of SwiftUI makes the catalog cheap to test and impossible for extensions to
/// drift from the app's source of truth.
public struct ForgeThemePalette: Equatable, Sendable {
    public let background: UInt32
    public let surface: UInt32
    public let surfaceElevated: UInt32
    public let surfaceHighlight: UInt32
    public let separator: UInt32

    public let accent: UInt32
    public let accentForeground: UInt32
    public let onAccent: UInt32
    public let secondaryAccent: UInt32
    public let secondaryAccentForeground: UInt32
    public let onSecondaryAccent: UInt32
    public let accentSoftOpacity: Double

    public let warmup: UInt32
    public let success: UInt32
    public let danger: UInt32
    public let recoveryLow: UInt32
    public let recoveryMid: UInt32
    public let recoveryHigh: UInt32
    public let zone1: UInt32
    public let zone2: UInt32
    public let zone3: UInt32
    public let zone4: UInt32
    public let zone5: UInt32
    public let stickyFill: UInt32
    public let stickyInk: UInt32
    public let textPrimary: UInt32
    public let textSecondary: UInt32
    public let textTertiary: UInt32
}

public enum ForgeThemeCatalog {
    public static func palette(
        for family: ThemeFamily,
        appearance: ForgeThemeAppearance
    ) -> ForgeThemePalette {
        switch appearance {
        case .dark: darkPalette(for: family)
        case .light: lightPalette(for: family)
        }
    }

    private struct BrandColors {
        let accent: UInt32
        let accentForeground: UInt32
        let onAccent: UInt32
        let secondary: UInt32
        let secondaryForeground: UInt32
        let onSecondary: UInt32
    }

    private static func darkPalette(for family: ThemeFamily) -> ForgeThemePalette {
        let brand: BrandColors = switch family {
        case .sage:
            BrandColors(
                accent: 0x55B374,
                accentForeground: 0x55B374,
                onAccent: 0x0E1116,
                secondary: 0x34D399,
                secondaryForeground: 0x34D399,
                onSecondary: 0x0E1116
            )
        case .rose:
            BrandColors(
                accent: 0xF062A3,
                accentForeground: 0xF47AB2,
                onAccent: 0x1C0D15,
                secondary: 0xFF9AC8,
                secondaryForeground: 0xFF9AC8,
                onSecondary: 0x1C0D15
            )
        case .ocean:
            BrandColors(
                accent: 0x4FA8FF,
                accentForeground: 0x67B5FF,
                onAccent: 0x07131D,
                secondary: 0x35D0C5,
                secondaryForeground: 0x35D0C5,
                onSecondary: 0x07131D
            )
        case .violet:
            BrandColors(
                accent: 0xA78BFA,
                accentForeground: 0xB69EFF,
                onAccent: 0x140D20,
                secondary: 0xD0B7FF,
                secondaryForeground: 0xD0B7FF,
                onSecondary: 0x140D20
            )
        case .ember:
            BrandColors(
                accent: 0xF4A340,
                accentForeground: 0xF7B45F,
                onAccent: 0x1C1105,
                secondary: 0xF7CA52,
                secondaryForeground: 0xF7CA52,
                onSecondary: 0x1C1105
            )
        case .graphite:
            BrandColors(
                accent: 0xAEB7C4,
                accentForeground: 0xC0C7D0,
                onAccent: 0x101318,
                secondary: 0x77C4E4,
                secondaryForeground: 0x77C4E4,
                onSecondary: 0x101318
            )
        }

        return ForgeThemePalette(
            background: 0x0E1116,
            surface: 0x181B21,
            surfaceElevated: 0x20242B,
            surfaceHighlight: 0x282D35,
            separator: 0x333942,
            accent: brand.accent,
            accentForeground: brand.accentForeground,
            onAccent: brand.onAccent,
            secondaryAccent: brand.secondary,
            secondaryAccentForeground: brand.secondaryForeground,
            onSecondaryAccent: brand.onSecondary,
            accentSoftOpacity: 0.18,
            warmup: 0xF5B93A,
            success: 0x35D07A,
            danger: 0xFF5A6E,
            recoveryLow: 0xFF5A6E,
            recoveryMid: 0xF5B93A,
            recoveryHigh: 0x35D07A,
            zone1: 0x8E8B99,
            zone2: 0x2AD4C6,
            zone3: 0xF5C518,
            zone4: 0xFF9F0A,
            zone5: 0xFF5A6E,
            stickyFill: 0xF6D66B,
            stickyInk: 0x2A2410,
            textPrimary: 0xFFFFFF,
            textSecondary: 0xA4ABA6,
            textTertiary: 0x747A74
        )
    }

    private static func lightPalette(for family: ThemeFamily) -> ForgeThemePalette {
        let brand: BrandColors = switch family {
        case .sage:
            BrandColors(
                accent: 0x2F9E58,
                accentForeground: 0x237A43,
                onAccent: 0x0E1116,
                secondary: 0x159873,
                secondaryForeground: 0x087052,
                onSecondary: 0x0E1116
            )
        case .rose:
            BrandColors(
                accent: 0xC72C78,
                accentForeground: 0xA91F61,
                onAccent: 0xFFFFFF,
                secondary: 0xA61E61,
                secondaryForeground: 0x8C174F,
                onSecondary: 0xFFFFFF
            )
        case .ocean:
            BrandColors(
                accent: 0x0877C9,
                accentForeground: 0x0568AC,
                onAccent: 0xFFFFFF,
                secondary: 0x087D75,
                secondaryForeground: 0x076A64,
                onSecondary: 0xFFFFFF
            )
        case .violet:
            BrandColors(
                accent: 0x7252C7,
                accentForeground: 0x6242B5,
                onAccent: 0xFFFFFF,
                secondary: 0x6841A8,
                secondaryForeground: 0x573692,
                onSecondary: 0xFFFFFF
            )
        case .ember:
            BrandColors(
                accent: 0xA9550A,
                accentForeground: 0x8A4507,
                onAccent: 0xFFFFFF,
                secondary: 0x8A6500,
                secondaryForeground: 0x735400,
                onSecondary: 0xFFFFFF
            )
        case .graphite:
            BrandColors(
                accent: 0x4D5968,
                accentForeground: 0x45515F,
                onAccent: 0xFFFFFF,
                secondary: 0x376D83,
                secondaryForeground: 0x2C5C70,
                onSecondary: 0xFFFFFF
            )
        }

        return ForgeThemePalette(
            background: 0xF3F5F1,
            surface: 0xFFFFFF,
            surfaceElevated: 0xFFFFFF,
            surfaceHighlight: 0xE8F3EA,
            separator: 0xDEE3DE,
            accent: brand.accent,
            accentForeground: brand.accentForeground,
            onAccent: brand.onAccent,
            secondaryAccent: brand.secondary,
            secondaryAccentForeground: brand.secondaryForeground,
            onSecondaryAccent: brand.onSecondary,
            accentSoftOpacity: 0.14,
            warmup: 0xB8790A,
            success: 0x1E9A55,
            danger: 0xE0334C,
            recoveryLow: 0xE0334C,
            recoveryMid: 0xB8790A,
            recoveryHigh: 0x1E9A55,
            zone1: 0x6B6876,
            zone2: 0x0E9A8E,
            zone3: 0x9A7D00,
            zone4: 0xC97400,
            zone5: 0xE0334C,
            stickyFill: 0xF6D66B,
            stickyInk: 0x2A2410,
            textPrimary: 0x14171A,
            textSecondary: 0x50594F,
            textTertiary: 0x82897F
        )
    }
}

public struct ForgeThemePreference: Codable, Equatable, Sendable {
    public var family: ThemeFamily
    public var mode: ForgeThemeMode

    public init(family: ThemeFamily = .sage, mode: ForgeThemeMode = .dark) {
        self.family = family
        self.mode = mode
    }
}

/// Cross-process storage used by the iPhone app and its extensions. The phone
/// still stores the individual raw values in standard defaults for backup and
/// reset; this compact mirror exists only for immediate extension rendering.
public enum ForgeThemePreferenceStore {
    public static let suiteName = "group.org.xpetsllc.ForgeFit"
    public static let key = "forgefit.theme.preference"

    public static func load(
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    ) -> ForgeThemePreference {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(ForgeThemePreference.self, from: data) else {
            return ForgeThemePreference()
        }
        return value
    }

    public static func save(
        _ preference: ForgeThemePreference,
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    ) {
        guard let data = try? JSONEncoder().encode(preference) else { return }
        defaults.set(data, forKey: key)
    }

    public static func reset(
        defaults: UserDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    ) {
        defaults.removeObject(forKey: key)
    }
}
