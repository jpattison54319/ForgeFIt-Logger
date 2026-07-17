import ForgeData
import SwiftData

/// The one way ForgeFitTests builds SwiftData stores.
///
/// `cloudKitDatabase: .none` is load-bearing: without it SwiftData attaches
/// CloudKit mirroring even to in-memory stores, and on simulators with no
/// iCloud account (always true in tests and CI) the failed mirroring setup
/// can tear down the store connection mid-test, crashing the test host with
/// NSInternalInconsistencyException "No eligible connection available".
/// Never construct a raw `ModelConfiguration` in this target.
@MainActor
enum TestStore {
    /// Returns the container WITH its main context: `mainContext` references
    /// its container weakly, so a caller that keeps only the context lets
    /// the container deinit mid-test — the context resets, every model is
    /// destroyed, and the SwiftData fatal takes down the whole test host
    /// (collaterally failing unrelated suites). Keep `container` alive for
    /// the test body even if you never touch it again.
    static func make() throws -> (container: ModelContainer, context: ModelContext) {
        let container = try makeContainer()
        return (container, container.mainContext)
    }

    /// Just the container, for suites that wrap it in their own
    /// `ModelContext(container)` — which, unlike `mainContext`, retains the
    /// container and does not autosave.
    static func makeContainer() throws -> ModelContainer {
        let schema = Schema(ForgeDataSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
