import Foundation

/// A deterministic, replayable user journey. The action text is descriptive
/// metadata; the XCTest implementation remains the authority for interaction.
struct AcceptanceScenario: Codable, Sendable {
    let id: String
    let title: String
    let purpose: String
    let fixtureArguments: [String]
    let checkpoints: [AcceptanceCheckpoint]
}

struct AcceptanceCheckpoint: Codable, Sendable {
    let id: String
    let title: String
    let action: String
    let expectedVisibleIdentifiers: [String]
    let expectedVisibleLabels: [String]
    let screenshotRequired: Bool
}

enum AcceptanceScenarioCatalog {
    static let representativeTour = AcceptanceScenario(
        id: "representative-app-tour",
        title: "Representative app tour",
        purpose: "Verify the primary iPhone shell and the first navigation surface from a known demo account.",
        fixtureArguments: [
            "--reset-store",
            "--skip-onboarding",
            "--seed-appstore-demo",
            "--seed-recovery-demo",
            "-didOnboard", "YES",
            "-weightUnitRaw", "lb",
            "-distanceUnitRaw", "mi",
            "-profileDisplayName", "Acceptance User",
            "-initialTab", "home"
        ],
        checkpoints: [
            AcceptanceCheckpoint(
                id: "home-shell",
                title: "Home shell is usable",
                action: "Launch the app from a clean deterministic account.",
                expectedVisibleIdentifiers: ["home-calendar", "tab-home", "tab-workout", "tab-insights", "tab-profile"],
                expectedVisibleLabels: ["Home"],
                screenshotRequired: true
            ),
            AcceptanceCheckpoint(
                id: "workout-tab",
                title: "Workout tab opens",
                action: "Open the Workout tab using the visible tab control.",
                expectedVisibleIdentifiers: ["tab-workout", "new-routine-button"],
                expectedVisibleLabels: ["Workout"],
                screenshotRequired: true
            ),
            AcceptanceCheckpoint(
                id: "insights-tab",
                title: "Insights tab opens",
                action: "Open the Insights tab using the visible tab control.",
                expectedVisibleIdentifiers: ["tab-insights", "insight-experiments-entry"],
                expectedVisibleLabels: ["Insights"],
                screenshotRequired: true
            ),
            AcceptanceCheckpoint(
                id: "profile-tab",
                title: "Profile tab opens",
                action: "Open the Profile tab using the visible tab control.",
                expectedVisibleIdentifiers: ["tab-profile", "profile-exercises"],
                expectedVisibleLabels: ["Profile"],
                screenshotRequired: true
            )
        ]
    )
}
