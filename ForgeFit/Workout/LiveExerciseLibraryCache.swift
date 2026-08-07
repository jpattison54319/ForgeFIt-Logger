import ForgeData
import Foundation

/// Keeps exercises created inside a presented workout available until the
/// logger's caller receives its next SwiftData query snapshot.
@MainActor
enum LiveExerciseLibraryCache {
    static func refreshedLookup(
        library: [ExerciseLibraryModel],
        retaining cached: [UUID: ExerciseLibraryModel]
    ) -> [UUID: ExerciseLibraryModel] {
        var result = cached
        let libraryByID = Dictionary(
            library.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        result.merge(libraryByID) { _, refreshed in refreshed }
        return result
    }

    /// Preserves the caller's stable ordering, then appends any session-created
    /// entries that have not reached that caller yet.
    static func librarySnapshot(
        library: [ExerciseLibraryModel],
        lookup: [UUID: ExerciseLibraryModel]
    ) -> [ExerciseLibraryModel] {
        var seen = Set<UUID>()
        var result = library.filter { seen.insert($0.id).inserted }
        let cachedOnly = lookup.values
            .filter { !seen.contains($0.id) }
            .sorted {
                let comparison = $0.name.localizedStandardCompare($1.name)
                return comparison == .orderedSame
                    ? $0.id.uuidString < $1.id.uuidString
                    : comparison == .orderedAscending
            }
        result.append(contentsOf: cachedOnly)
        return result
    }
}
