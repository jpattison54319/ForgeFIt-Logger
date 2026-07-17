import ForgeData
import SwiftUI
import SwiftData

@main
struct ForgeFitApp: App {
    @StateObject private var themeManager = ThemeManager()

    init() {
        // Generous shared URL cache so exercise illustrations survive offline
        // gym sessions once they've been seen.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024
        )
        // BGTaskScheduler requires registration before the app finishes
        // launching; the rest of ReadinessDelivery is wired in launchTasks.
        ReadinessDelivery.shared.register()
        // UI-test hook. Seeding the pref via a `-quickActionBubble.v1 <json>`
        // launch argument shadows application-domain writes for the whole
        // process (the argument domain wins every read), so write-then-read
        // tests clear the stored value up front instead of pinning it.
        if ProcessInfo.processInfo.arguments.contains("--reset-quick-actions") {
            UserDefaults.standard.removeObject(forKey: AppQuickActionStore.key)
        }
    }

    // Split persistence (5.1.3(ii)): local-only training log + CloudKit
    // plan store, with the one-time legacy migration. See PersistenceBootstrap.
    var sharedModelContainer: ModelContainer = PersistenceBootstrap.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                // Dynamic Type is token-anchored (Theme.swift type ramp); the
                // ceiling keeps dense fixed-frame surfaces — the set-entry
                // grid, tab bar, 44 pt headers — usable at the largest sizes.
                // AX1 is the largest size the layouts were audited at; raise
                // only with a fresh layout pass.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .modelContainer(sharedModelContainer)
    }
}
