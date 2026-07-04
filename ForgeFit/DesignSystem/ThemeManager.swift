import Combine
import SwiftUI

/// Holds the active `AppTheme` so the root view can inject it into the
/// environment. Only `.sage` is registered today; this is the future hook for
/// adding user-selectable color schemes + persistence.
@MainActor
final class ThemeManager: ObservableObject {
    @Published var current: AppTheme = .sage
}
