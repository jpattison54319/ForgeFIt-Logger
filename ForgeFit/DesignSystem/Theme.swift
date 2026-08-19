import ForgeCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Theme

/// Sage color scheme — slate obsidian canvas with neutral slate surfaces and
/// an Active Sage / Fresh Mint accent duotone. Expressed as a value type so the
/// active theme can be injected via the SwiftUI environment and swapped at
/// runtime in a future update.
struct AppTheme {
    let family: ThemeFamily

    // Canvas & surfaces
    let background: Color
    let surface: Color
    let surfaceElevated: Color
    let surfaceHighlight: Color
    let separator: Color

    // Brand — Active Sage primary, Fresh Mint secondary
    let accent: Color
    /// Brand color when used as foreground content on a canvas or surface.
    let accentForeground: Color
    /// Foreground content placed directly on an accent-filled control.
    let onAccent: Color
    let accentSoft: Color
    let secondaryAccent: Color
    let secondaryAccentForeground: Color
    let onSecondaryAccent: Color
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
    static let sageDark = make(family: .sage, appearance: .dark)

    static let sage = sageDark

    /// Same Sage/Mint brand hues, tuned for a light canvas: signal colors are
    /// deepened so they clear ~4.5:1 contrast against white/near-white
    /// surfaces (the dark-mode values are pale enough to read fine on a
    /// near-black canvas but wash out on white). Sticky-note colors are
    /// intentionally unchanged — they represent a fixed "paper" surface, not
    /// part of the app chrome.
    static let sageLight = make(family: .sage, appearance: .light)

    /// Resolves which variant is active for a chosen `ThemeMode` + the
    /// device's live system appearance.
    static func active(
        family: ThemeFamily,
        mode: ThemeMode,
        system: ColorScheme
    ) -> AppTheme {
        make(
            family: family,
            appearance: mode.resolvedColorScheme(system: system) == .dark ? .dark : .light
        )
    }

    static func active(for mode: ThemeMode, system: ColorScheme) -> AppTheme {
        active(family: .sage, mode: mode, system: system)
    }

    /// Share exports intentionally stay dark for predictable rendering while
    /// still carrying the user's selected color family.
    static func export(family: ThemeFamily) -> AppTheme {
        make(family: family, appearance: .dark)
    }

    private static func make(
        family: ThemeFamily,
        appearance: ForgeThemeAppearance
    ) -> AppTheme {
        let palette = ForgeThemeCatalog.palette(for: family, appearance: appearance)
        return AppTheme(
            family: family,
            background: Color(hex: palette.background),
            surface: Color(hex: palette.surface),
            surfaceElevated: Color(hex: palette.surfaceElevated),
            surfaceHighlight: Color(hex: palette.surfaceHighlight),
            separator: Color(hex: palette.separator),
            accent: Color(hex: palette.accent),
            accentForeground: Color(hex: palette.accentForeground),
            onAccent: Color(hex: palette.onAccent),
            accentSoft: Color(hex: palette.accent).opacity(palette.accentSoftOpacity),
            secondaryAccent: Color(hex: palette.secondaryAccent),
            secondaryAccentForeground: Color(hex: palette.secondaryAccentForeground),
            onSecondaryAccent: Color(hex: palette.onSecondaryAccent),
            warmup: Color(hex: palette.warmup),
            success: Color(hex: palette.success),
            danger: Color(hex: palette.danger),
            recoveryLow: Color(hex: palette.recoveryLow),
            recoveryMid: Color(hex: palette.recoveryMid),
            recoveryHigh: Color(hex: palette.recoveryHigh),
            zone1: Color(hex: palette.zone1),
            zone2: Color(hex: palette.zone2),
            zone3: Color(hex: palette.zone3),
            zone4: Color(hex: palette.zone4),
            zone5: Color(hex: palette.zone5),
            stickyFill: Color(hex: palette.stickyFill),
            stickyInk: Color(hex: palette.stickyInk),
            textPrimary: Color(hex: palette.textPrimary),
            textSecondary: Color(hex: palette.textSecondary),
            textTertiary: Color(hex: palette.textTertiary)
        )
    }
}

// MARK: - Appearance mode

/// The user's chosen appearance. `.system` tracks the device's live
/// light/dark setting; `.light`/`.dark` pin the app regardless of the
/// device setting. Persisted via `ThemeManager`, surfaced in Settings.
typealias ThemeMode = ForgeThemeMode

extension ForgeThemeMode {
    var label: String {
        displayName
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

// MARK: - Motion

/// Motion tokens — the app's animation voice, one tier per job. Pick a token
/// instead of an inline curve so state feedback times identically on every
/// screen. (The staged Liquid Glass choreography in `GlassDivisionMenu` /
/// `QuickIncrementFan` keeps its own bespoke springs by design.)
///
/// Reduce Motion: pure value morphs (numeric text rolls, color/fill changes,
/// opacity crossfades) run untouched; anything that moves, scales, bounces,
/// or staggers must swap to `Motion.reduced` or an opacity transition — the
/// transition helpers below do this given the environment's
/// `accessibilityReduceMotion` flag.
enum Motion {
    /// Immediate feedback on a tap or a per-second value tick.
    static let tap: Animation = .easeOut(duration: 0.15)
    /// A value or state changing in place. Matches the logger's set-completion
    /// timing (`.snappy(0.28)`) so existing and new feedback speak together.
    static let stateChange: Animation = .snappy(duration: 0.28)
    /// A view arriving or departing (cards, strips, floating buttons).
    static let entrance: Animation = .spring(duration: 0.35)
    /// One-shot reward moments (XP fills, level-ups). Rare by design.
    static let reward: Animation = .easeOut(duration: 0.6)
    /// Short crossfade substituted for any token when Reduce Motion is on.
    static let reduced: Animation = .easeOut(duration: 0.15)

    /// Rise-from-bottom entrance; collapses to a fade under Reduce Motion.
    static func riseIn(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// Directional slide for paged content (calendar months); fades under
    /// Reduce Motion.
    static func slide(from edge: Edge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    /// Gentle scale-and-fade entrance; collapses to a fade under Reduce Motion.
    static func scaleIn(
        _ scale: CGFloat = 0.9,
        anchor: UnitPoint = .center,
        reduceMotion: Bool
    ) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: scale, anchor: anchor).combined(with: .opacity)
    }
}

// MARK: - Typography

/// The type ramp is anchored to system text styles so every token scales
/// with the user's Text Size setting (Dynamic Type). Each anchor's DEFAULT
/// size equals the token's original fixed point size, so nothing shifts at
/// the standard (Large) setting. The app root clamps growth at
/// `.accessibility1` (see ForgeFitApp) so dense fixed-frame surfaces stay
/// usable — raise the ceiling only after auditing those layouts.
extension Font {
    static let screenTitle = Font.system(.largeTitle, design: .default, weight: .bold)   // 34
    static let sectionTitle = Font.system(.title2, weight: .bold)                        // 22
    static let cardTitle = Font.system(.title3, weight: .semibold)                       // 20
    static let statValue = Font.system(.title2, weight: .semibold)                       // 22
    static let bodyStrong = Font.system(.callout, weight: .semibold)                     // 16
    static let rowValue = Font.system(.body, weight: .semibold)                          // 17
    static let label = Font.system(.footnote, weight: .medium)                           // 13
    static let tag = Font.system(.caption, weight: .semibold)                            // 12

    /// 30 pt sits between `.title` (28) and `.largeTitle` (34), so it scales
    /// through UIFontMetrics against `.title1` instead of a style anchor. The
    /// growth cap mirrors the app-wide `.accessibility1` clamp — UIFontMetrics
    /// reads UIKit's content size directly and would otherwise ignore it.
    @MainActor
    static var metricValue: Font {
        #if os(iOS)
        let capped = min(UIApplication.shared.preferredContentSizeCategory, .accessibilityMedium)
        let size = UIFontMetrics(forTextStyle: .title1)
            .scaledValue(for: 30, compatibleWith: UITraitCollection(preferredContentSizeCategory: capped))
        return Font.system(size: size, weight: .bold)
        #else
        return Font.system(size: 30, weight: .bold)
        #endif
    }
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
