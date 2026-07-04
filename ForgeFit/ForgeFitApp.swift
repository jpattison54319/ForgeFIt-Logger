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
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema(ForgeDataSchema.models)
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Store couldn't migrate to the current schema. Back the files up
            // first — user data must never be silently destroyed — then reset
            // and retry rather than crashing.
            let storeURL = modelConfiguration.url
            let dir = storeURL.deletingLastPathComponent()
            let base = storeURL.lastPathComponent
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backupDir = dir.appendingPathComponent("StoreBackup-\(stamp)", isDirectory: true)
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            for name in [base, base + "-shm", base + "-wal"] {
                let source = dir.appendingPathComponent(name)
                try? FileManager.default.copyItem(at: source, to: backupDir.appendingPathComponent(name))
                try? FileManager.default.removeItem(at: source)
            }
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeManager)
                .environment(\.theme, themeManager.current)
        }
        .modelContainer(sharedModelContainer)
    }
}
