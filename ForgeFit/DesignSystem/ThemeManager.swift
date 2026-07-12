import Combine
import SwiftUI

/// Holds the user's chosen appearance mode (System/Light/Dark). Persisted by
/// hand to `UserDefaults` rather than `@AppStorage` — that property wrapper
/// only refreshes correctly when used directly on a `View`, and this needs to
/// be readable from `ForgeFitApp` and resettable from `AccountResetService`.
///
/// `ContentView` combines `mode` with the live system `colorScheme` to
/// resolve which `AppTheme` variant is actually active — see
/// `AppTheme.active(for:system:)`. Only `.sageDark`/`.sageLight` are
/// registered today; this is the future hook for adding fully
/// user-selectable color schemes.
@MainActor
final class ThemeManager: ObservableObject {
    static let modeDefaultsKey = "themeModeRaw"

    @Published var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey) }
    }

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.modeDefaultsKey)
        mode = raw.flatMap(ThemeMode.init(rawValue:)) ?? .dark
    }
}
