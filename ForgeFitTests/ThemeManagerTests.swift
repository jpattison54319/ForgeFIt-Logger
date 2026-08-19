import ForgeCore
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct ThemeManagerTests {
    @Test func defaultsToSageDarkAndMirrorsForExtensions() throws {
        let stores = try makeStores()
        defer { stores.cleanup() }

        let manager = ThemeManager(
            defaults: stores.app,
            sharedDefaults: stores.shared
        )

        #expect(manager.family == .sage)
        #expect(manager.mode == .dark)
        #expect(ForgeThemePreferenceStore.load(defaults: stores.shared) == ForgeThemePreference())
    }

    @Test func selectionPersistsAndReloadsAfterExternalRestore() throws {
        let stores = try makeStores()
        defer { stores.cleanup() }
        let manager = ThemeManager(
            defaults: stores.app,
            sharedDefaults: stores.shared
        )

        manager.family = .rose
        manager.mode = .system

        #expect(stores.app.string(forKey: ThemeManager.familyDefaultsKey) == ThemeFamily.rose.rawValue)
        #expect(stores.app.string(forKey: ThemeManager.modeDefaultsKey) == ForgeThemeMode.system.rawValue)
        #expect(ForgeThemePreferenceStore.load(defaults: stores.shared) == ForgeThemePreference(
            family: .rose,
            mode: .system
        ))

        stores.app.set(ThemeFamily.ocean.rawValue, forKey: ThemeManager.familyDefaultsKey)
        stores.app.set(ForgeThemeMode.light.rawValue, forKey: ThemeManager.modeDefaultsKey)
        manager.reload()

        #expect(manager.family == .ocean)
        #expect(manager.mode == .light)
        #expect(ForgeThemePreferenceStore.load(defaults: stores.shared) == ForgeThemePreference(
            family: .ocean,
            mode: .light
        ))
    }

    @Test func invalidValuesFailClosedAndThemePreferenceIsBackedUp() throws {
        let stores = try makeStores()
        defer { stores.cleanup() }
        stores.app.set("retired", forKey: ThemeManager.familyDefaultsKey)
        stores.app.set("unknown", forKey: ThemeManager.modeDefaultsKey)

        let manager = ThemeManager(
            defaults: stores.app,
            sharedDefaults: stores.shared
        )

        #expect(manager.family == .sage)
        #expect(manager.mode == .dark)
        #expect(AppPreferenceKeys.backedUp.contains(ThemeManager.familyDefaultsKey))
        #expect(AppPreferenceKeys.backedUp.contains(ThemeManager.modeDefaultsKey))
    }

    private func makeStores() throws -> (
        app: UserDefaults,
        shared: UserDefaults,
        cleanup: () -> Void
    ) {
        let appSuite = "ThemeManagerTests-app-\(UUID().uuidString)"
        let sharedSuite = "ThemeManagerTests-shared-\(UUID().uuidString)"
        let app = try #require(UserDefaults(suiteName: appSuite))
        let shared = try #require(UserDefaults(suiteName: sharedSuite))
        return (app, shared, {
            app.removePersistentDomain(forName: appSuite)
            shared.removePersistentDomain(forName: sharedSuite)
        })
    }
}
