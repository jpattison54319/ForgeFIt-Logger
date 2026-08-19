import SwiftUI

/// Routes for settings detail screens, used with
/// `navigationDestination(for:)`.
enum SettingsRoute: Hashable {
    case theme
    case heartRateZones
    case warmupRamp
    case platesAndBars
    case resistanceBands
    case reminders
    case yogaGuidance
    case iCloudBackup
    case privacyPolicy
}
