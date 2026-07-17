import SwiftUI

/// Top-most settings section: three-column connection status hero for Apple
/// Health, Apple Watch, and Bluetooth HR monitor.
struct SettingsHeroSection: View {
    let healthConnected: Bool
    let watchPaired: Bool
    let hrmConnected: Bool

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
