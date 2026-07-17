import SwiftUI

/// Routes for settings detail screens, used with
/// `navigationDestination(for:)`.
enum SettingsRoute: Hashable {
    case heartRateZones
    case warmupRamp
    case platesAndBars
    case reminders
    case privacyPolicy
}
