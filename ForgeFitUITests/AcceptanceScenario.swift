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

    static let routineMalformedPercentageSaveGuard = AcceptanceScenario(
        id: "routine-malformed-percentage-save-guard",
        title: "Malformed routine percentage blocks Save",
        purpose: "Verify malformed percentage text remains editable, has a non-color error receipt, and cannot dismiss the routine editor.",
        fixtureArguments: routineLoadPrescriptionFixtureArguments,
        checkpoints: [
            AcceptanceCheckpoint(
                id: "routine-fixture-ready",
                title: "Seeded routine is available",
                action: "Launch the Workout tab with the deterministic Long Routine fixture.",
                expectedVisibleIdentifiers: ["routine-menu-Long Routine", "new-routine-button"],
                expectedVisibleLabels: ["Long Routine"],
                screenshotRequired: true,
                phase: .setup
            ),
            AcceptanceCheckpoint(
                id: "routine-editor-ready",
                title: "Routine editor opens",
                action: "Open Long Routine for editing.",
                expectedVisibleIdentifiers: ["routine-editor-scroll", "routine-editor-save-button"],
                expectedVisibleLabels: [],
                screenshotRequired: true
            ),
            AcceptanceCheckpoint(
                id: "malformed-percentage-visible",
                title: "Malformed percentage remains visible",
                action: "Blur the malformed percentage field.",
                expectedVisibleIdentifiers: ["routine-set-load-invalid", "routine-editor-save-button"],
                expectedVisibleLabels: ["Percentage of estimated one rep max"],
                screenshotRequired: true,
                invariants: ["The malformed text remains exactly 67--72 and the error is not communicated by color alone."]
            ),
            AcceptanceCheckpoint(
                id: "malformed-percentage-save-blocked",
                title: "Save explains the invalid value",
                action: "Tap Save while the malformed percentage is still present.",
                expectedVisibleIdentifiers: ["routine-editor-save-button"],
                expectedVisibleLabels: ["Check Routine Values"],
                screenshotRequired: true,
                invariants: ["The routine editor remains mounted and no malformed percentage is persisted."]
            )
        ]
    )

    static let routineMalformedPercentageLifecycle = AcceptanceScenario(
        id: "routine-malformed-percentage-lifecycle",
        title: "Malformed routine percentage stays local across lifecycle changes",
        purpose: "Verify backgrounding preserves the live malformed draft without replacing the last valid persisted percentage.",
        fixtureArguments: routineLoadPrescriptionFixtureArguments,
        checkpoints: [
            AcceptanceCheckpoint(
                id: "routine-fixture-ready",
                title: "Seeded routine is available",
                action: "Launch the Workout tab with the deterministic Long Routine fixture.",
                expectedVisibleIdentifiers: ["routine-menu-Long Routine", "new-routine-button"],
                expectedVisibleLabels: ["Long Routine"],
                screenshotRequired: true,
                phase: .setup
            ),
            AcceptanceCheckpoint(
                id: "routine-editor-ready",
                title: "Routine editor opens",
                action: "Open Long Routine for editing.",
                expectedVisibleIdentifiers: ["routine-editor-scroll", "routine-editor-save-button"],
                expectedVisibleLabels: [],
                screenshotRequired: true
            ),
            AcceptanceCheckpoint(
                id: "malformed-percentage-restored",
                title: "Foregrounding restores the local malformed draft",
                action: "Return to the still-live routine editor after backgrounding.",
                expectedVisibleIdentifiers: ["routine-set-load-invalid", "routine-editor-save-button"],
                expectedVisibleLabels: ["Percentage of estimated one rep max"],
                screenshotRequired: true,
                invariants: ["The field still reads exactly 67--72 and remains visibly invalid."]
            ),
            AcceptanceCheckpoint(
                id: "last-valid-percentage-persists",
                title: "Relaunch restores only the last valid percentage",
                action: "Terminate and reopen Long Routine from the same persisted store.",
                expectedVisibleIdentifiers: ["routine-editor-scroll", "routine-editor-save-button"],
                expectedVisibleLabels: ["Percentage of estimated one rep max"],
                screenshotRequired: true,
                invariants: ["The field reads exactly 70 and has no invalid-state receipt."]
            )
        ]
    )

    private static let routineLoadPrescriptionFixtureArguments = [
        "--reset-store",
        "--seed-routine-hierarchy-many-exercises",
        "--skip-onboarding",
        "--suppress-health-refresh",
        "-didOnboard", "YES",
        "-weightUnitRaw", "kg",
        "-initialTab", "workout",
    ]
}
