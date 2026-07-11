import SwiftUI

/// Routes for settings detail screens, used with
/// `navigationDestination(for:)`.
enum SettingsRoute: Hashable {
    case heartRateZones
    case platesAndBars
    case reminders
    case privacyPolicy
}
