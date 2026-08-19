import ForgeData
import SwiftUI
import SwiftData

@main
struct ForgeFitApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme
    @StateObject private var themeManager = ThemeManager()
    @State private var persistenceState: PersistenceLaunchState

    private var activeTheme: AppTheme {
        .active(
            family: themeManager.family,
            mode: themeManager.mode,
            system: systemColorScheme
        )
    }

    private var resolvedColorScheme: ColorScheme {
        themeManager.mode.resolvedColorScheme(system: systemColorScheme)
    }

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
        // UserNotifications can deliver a response while iOS is restoring the
        // scene after a cold-launch tap, so its main-actor delegate must exist
        // before launch completes.
        NotificationScheduler.shared.activate()
        // UI-test hook. Seeding the pref via a `-quickActionBubble.v1 <json>`
        // launch argument shadows application-domain writes for the whole
        // process (the argument domain wins every read), so write-then-read
        // tests clear the stored value up front instead of pinning it.
        if ProcessInfo.processInfo.arguments.contains("--reset-quick-actions") {
            UserDefaults.standard.removeObject(forKey: AppQuickActionStore.key)
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--simulate-persistence-failure") {
            // UI-test-only launch seam. It proves the app can reach the
            // recovery surface without first touching a persistent store.
            _persistenceState = State(initialValue: .blocked(.workoutLogUnavailable))
        } else {
            _persistenceState = State(initialValue: PersistenceBootstrap.makeContainer())
        }
        #else
        _persistenceState = State(initialValue: PersistenceBootstrap.makeContainer())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                switch persistenceState {
                case let .ready(container):
                    ContentView()
                        .modelContainer(container)
                        // A last-resort durability boundary for any direct
                        // model binding an editor forgot to commit itself.
                        // Inactive arrives before iOS can suspend or replace
                        // the process during an over-install.
                        .onChange(of: scenePhase) { _, phase in
                            guard phase != .active,
                                  container.mainContext.hasChanges else { return }
                            container.mainContext.saveUserChanges()
                        }
                case let .blocked(failure):
                    PersistenceRecoveryView(failure: failure) {
                        persistenceState = PersistenceBootstrap.makeContainer()
                    }
                }
            }
            .environmentObject(themeManager)
            // Install the user's selection above the entire scene. This keeps
            // every descendant presentation (including sheets hosted outside
            // a view's local modifier chain) on the same resolved family.
            .environment(\.theme, activeTheme)
            .preferredColorScheme(resolvedColorScheme)
            .tint(activeTheme.accent)
            .persistentChangeSaveAlert()
            // Dynamic Type is token-anchored (Theme.swift type ramp); the
            // ceiling keeps dense fixed-frame surfaces — the set-entry grid,
            // tab bar, and 44 pt headers usable at the largest audited size.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
}
