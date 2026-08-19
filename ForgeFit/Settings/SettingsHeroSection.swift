import SwiftUI

/// Top-most settings section: connection status hero for Apple Health, Apple
/// Watch, and — when the feature is available — a Bluetooth HR monitor.
struct SettingsHeroSection: View {
    let healthConnected: Bool
    let watchPaired: Bool
    let hrmConnected: Bool?

    var body: some View {
        Section {
            ConnectionStatusHero(
                healthConnected: healthConnected,
                watchPaired: watchPaired,
                hrmConnected: hrmConnected
            )
            .themedListRow()
        }
    }
}
