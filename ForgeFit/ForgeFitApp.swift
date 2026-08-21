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
        // launching. The rest of ReadinessDelivery is wired below, once the
        // container exists.
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

        let launchState: PersistenceLaunchState
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--simulate-persistence-failure") {
            // UI-test-only launch seam. It proves the app can reach the
            // recovery surface without first touching a persistent store.
            launchState = .blocked(.workoutLogUnavailable)
        } else {
            launchState = PersistenceBootstrap.makeContainer()
        }
        #else
        launchState = PersistenceBootstrap.makeContainer()
        #endif
        _persistenceState = State(initialValue: launchState)

        // Readiness wake-ups must not depend on a scene. iOS launches this
        // process into the background for the pre-dawn BGAppRefresh and for
        // HealthKit's overnight sleep/HRV delivery, and in that launch no
        // window is ever created — so `launchTasks()` never runs and, wired
        // only from there, this stayed unconfigured: the observer queries
        // were never executed to receive the wake, and the refresh found a
        // nil container and scored nothing. `configure` is documented safe to
        // call again, and the scene still calls it on every foreground.
        if let container = launchState.container {
            ReadinessDelivery.shared.configure(container: container)
        }
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
