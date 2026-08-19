import Foundation
import Testing
@testable import ForgeCore

struct ForgeThemeTests {
    @Test func catalogHasStableApprovedFamilies() {
        #expect(ThemeFamily.allCases.map(\.rawValue) == [
            "sage", "rose", "ocean", "violet", "ember", "graphite",
        ])
    }

    @Test func semanticColorsDoNotChangeWithBrandFamily() {
        for appearance in [ForgeThemeAppearance.light, .dark] {
            let sage = ForgeThemeCatalog.palette(for: .sage, appearance: appearance)
            for family in ThemeFamily.allCases {
                let palette = ForgeThemeCatalog.palette(for: family, appearance: appearance)
                #expect(palette.warmup == sage.warmup)
                #expect(palette.success == sage.success)
                #expect(palette.danger == sage.danger)
                #expect(palette.recoveryLow == sage.recoveryLow)
                #expect(palette.recoveryMid == sage.recoveryMid)
                #expect(palette.recoveryHigh == sage.recoveryHigh)
                #expect(palette.zone1 == sage.zone1)
                #expect(palette.zone2 == sage.zone2)
                #expect(palette.zone3 == sage.zone3)
                #expect(palette.zone4 == sage.zone4)
                #expect(palette.zone5 == sage.zone5)
            }
        }
    }

    @Test func brandForegroundPairsMeetNormalTextContrast() {
        for family in ThemeFamily.allCases {
            for appearance in [ForgeThemeAppearance.light, .dark] {
                let palette = ForgeThemeCatalog.palette(for: family, appearance: appearance)
                #expect(contrast(palette.accentForeground, palette.surface) >= 4.5)
                #expect(contrast(palette.onAccent, palette.accent) >= 4.5)
                #expect(contrast(palette.secondaryAccentForeground, palette.surface) >= 4.5)
                #expect(contrast(palette.onSecondaryAccent, palette.secondaryAccent) >= 4.5)
                #expect(contrast(palette.textPrimary, palette.background) >= 4.5)
            }
        }
    }

    @Test func darkBaseBrandColorsRemainReadableOnWatchSurfaces() {
        for family in ThemeFamily.allCases {
            let palette = ForgeThemeCatalog.palette(for: family, appearance: .dark)
            #expect(contrast(palette.accent, palette.surface) >= 4.5)
            #expect(contrast(palette.secondaryAccent, palette.surface) >= 4.5)
        }
    }

    @Test func preferenceStoreRoundTripsAndFailsClosedToSageDark() throws {
        let suite = "ForgeThemeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ForgeThemePreferenceStore.load(defaults: defaults) == ForgeThemePreference())

        let rose = ForgeThemePreference(family: .rose, mode: .system)
        ForgeThemePreferenceStore.save(rose, defaults: defaults)
        #expect(ForgeThemePreferenceStore.load(defaults: defaults) == rose)

        defaults.set(Data("{\"family\":\"retired\",\"mode\":\"light\"}".utf8), forKey: ForgeThemePreferenceStore.key)
        #expect(ForgeThemePreferenceStore.load(defaults: defaults) == ForgeThemePreference())

        ForgeThemePreferenceStore.reset(defaults: defaults)
        #expect(defaults.object(forKey: ForgeThemePreferenceStore.key) == nil)
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        let lighter = max(firstLuminance, secondLuminance)
        let darker = min(firstLuminance, secondLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ hex: UInt32) -> Double {
        let components = [
            Double((hex >> 16) & 0xFF) / 255,
            Double((hex >> 8) & 0xFF) / 255,
            Double(hex & 0xFF) / 255,
        ].map { component in
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0]
            + 0.7152 * components[1]
            + 0.0722 * components[2]
    }
}
