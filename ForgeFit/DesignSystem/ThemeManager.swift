import Combine
import ForgeCore
import SwiftUI

/// Holds the user's chosen appearance mode (System/Light/Dark). Persisted by
/// hand to `UserDefaults` rather than `@AppStorage` — that property wrapper
/// only refreshes correctly when used directly on a `View`, and this needs to
/// be readable from `ForgeFitApp` and resettable from `AccountResetService`.
///
/// `ContentView` combines `family` and `mode` with the live system
/// `colorScheme` to resolve the active `AppTheme` variant.
@MainActor
final class ThemeManager: ObservableObject {
    static let modeDefaultsKey = "themeModeRaw"
    static let familyDefaultsKey = "themeFamilyRaw"

    private let defaults: UserDefaults
    private let sharedDefaults: UserDefaults

    @Published var mode: ThemeMode {
        didSet {
            guard oldValue != mode else { return }
            persistPreference()
        }
    }

    @Published var family: ThemeFamily {
        didSet {
            guard oldValue != family else { return }
            persistPreference()
        }
    }

    init(
        defaults: UserDefaults = .standard,
        sharedDefaults: UserDefaults = UserDefaults(
            suiteName: ForgeThemePreferenceStore.suiteName
        ) ?? .standard
    ) {
        self.defaults = defaults
        self.sharedDefaults = sharedDefaults
        let raw = defaults.string(forKey: Self.modeDefaultsKey)
        mode = raw.flatMap(ThemeMode.init(rawValue:)) ?? .dark
        let familyRaw = defaults.string(forKey: Self.familyDefaultsKey)
        family = familyRaw.flatMap(ThemeFamily.init(rawValue:)) ?? .sage
        mirrorPreference()
    }

    /// Re-read preferences after a backup restore writes UserDefaults outside
    /// this observable object. Invalid or missing values deliberately return
    /// to the same Sage/Dark fallback as a clean install.
    func reload() {
        let storedMode = defaults.string(forKey: Self.modeDefaultsKey)
            .flatMap(ThemeMode.init(rawValue:)) ?? .dark
        let storedFamily = defaults.string(forKey: Self.familyDefaultsKey)
            .flatMap(ThemeFamily.init(rawValue:)) ?? .sage
        mode = storedMode
        family = storedFamily
        mirrorPreference()
    }

    func reset() {
        mode = .dark
        family = .sage
        persistPreference()
    }

    private func persistPreference() {
        defaults.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        defaults.set(family.rawValue, forKey: Self.familyDefaultsKey)
        mirrorPreference()
    }

    private func mirrorPreference() {
        ForgeThemePreferenceStore.save(
            ForgeThemePreference(family: family, mode: mode),
            defaults: sharedDefaults
        )
    }
}
