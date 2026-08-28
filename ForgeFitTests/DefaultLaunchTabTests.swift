import Foundation
import Testing
@testable import ForgeFit

struct DefaultLaunchTabTests {
    @Test @MainActor func homeIsTheDefaultLaunchTab() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(DefaultLaunchTab.load(from: defaults) == .home)
        #expect(AppState(defaults: defaults).selectedTab == .home)
    }

    @Test @MainActor func workoutCanBeTheLaunchTab() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DefaultLaunchTab.workout.rawValue, forKey: DefaultLaunchTab.key)

        #expect(DefaultLaunchTab.load(from: defaults) == .workout)
        #expect(AppState(defaults: defaults).selectedTab == .workout)
    }

    @Test func invalidStoredValueFallsBackToHome() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-tab", forKey: DefaultLaunchTab.key)

        #expect(DefaultLaunchTab.load(from: defaults) == .home)
    }

    @Test func preferenceIsIncludedInBackupAndReset() {
        #expect(AppPreferenceKeys.backedUp.contains(DefaultLaunchTab.key))
        #expect(AppPreferenceKeys.allResettable.contains(DefaultLaunchTab.key))
    }

    @Test @MainActor func resetIgnoresAStaleAutomationTabButHonorsCurrentOverride() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppTab.workout.rawValue, forKey: "initialTab")

        #expect(AppState(
            defaults: defaults,
            arguments: ["ForgeFit", "--reset-store"]
        ).selectedTab == .home)
        #expect(AppState(
            defaults: defaults,
            arguments: ["ForgeFit", "--reset-store", "-initialTab", "workout"]
        ).selectedTab == .workout)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "defaultLaunchTabTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
