import Foundation

/// Version stamp for the bundled seed catalogs. Launch seeding (global
/// exercise library, exercise catalog + muscle refinement, yoga poses) used
/// to re-materialize the whole ~900-row library ~6× on every cold launch, on
/// the main actor, behind the boot splash. It now runs only when this version
/// bumps, the store looks empty, or a reset was forced.
///
/// BUMP `currentVersion` when ANY of these change:
/// - Resources/exercises.json (ExerciseCatalog seeds/thumbnails)
/// - GlobalExerciseLibrary.snapshot or ExerciseSeedRepository mapping logic
/// - YogaPoseCatalog poses or its prune list
/// - MuscleRefinement rules
enum LaunchSeedPolicy {
    static let currentVersion = 1
    static let defaultsKey = "seed.catalogVersion"

    /// Pure decision (unit-tested): seed when a reset wiped the store, when
    /// the stored stamp is behind the bundled catalogs, or when the library
    /// is empty — which catches stores recreated behind UserDefaults' back
    /// (e.g. the migration-failure reset in `ForgeFitApp`).
    static func shouldSeed(
        storedVersion: Int,
        currentVersion: Int = LaunchSeedPolicy.currentVersion,
        libraryCount: Int,
        forcedReset: Bool
    ) -> Bool {
        forcedReset || storedVersion < currentVersion || libraryCount == 0
    }
}
