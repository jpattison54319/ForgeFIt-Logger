import ForgeData
import Foundation

/// Body-safe single-slot memo: a reference type held in `@State` so an
/// expensive derived value survives body evaluations without triggering
/// re-renders. Mutating it during `body` is safe — it is not observable.
///
///     @State private var recoveryMemo = Memo<String, RecoveryEngine.Report>()
///     var recovery: RecoveryEngine.Report {
///         recoveryMemo(AnalyticsFingerprint.withHealth(workouts)) { computeReport() }
///     }
final class Memo<Key: Equatable, Value> {
    private var key: Key?
    private var cached: Value?

    var cachedValue: Value? { cached }

    func callAsFunction(_ key: Key, compute: () -> Value) -> Value {
        if let cached, self.key == key { return cached }
        let value = compute()
        self.key = key
        cached = value
        return value
    }
}

/// Multi-key variant for per-item caches (e.g. one entry per exercise). The
/// whole table shares one invalidation key — when it changes, everything
/// clears at once.
final class MemoTable<Key: Hashable, Value> {
    private var generation: String?
    private var cache: [Key: Value] = [:]

    func value(for key: Key, generation: String, compute: () -> Value) -> Value {
        if self.generation != generation {
            cache.removeAll(keepingCapacity: true)
            self.generation = generation
        }
        if let hit = cache[key] { return hit }
        let value = compute()
        cache[key] = value
        return value
    }
}

/// Cheap change-detection key for anything derived from workout history.
/// O(workouts) with no relationship walk. Every completed parent row is mixed
/// into the key, so an edit to older history cannot hide behind a newer row's
/// maximum timestamp. Workout mutation boundaries must stamp `updatedAt` when
/// changing nested authored data; this keeps render-path detection shallow.
///
/// IN-PROGRESS workouts contribute nothing. Every memo consumer computes over
/// completed workouts, so starting or editing a live session must not wake the
/// keep-resident tabs behind the logger. Finishing still invalidates.
enum AnalyticsFingerprint {
    static func of(_ workouts: [WorkoutModel]) -> String {
        var hasher = Hasher()
        var ended = 0
        for workout in workouts where workout.deletedAt == nil {
            guard workout.endedAt != nil else { continue }
            ended += 1
            hasher.combine(workout.id)
            hasher.combine(workout.routineID)
            hasher.combine(workout.startedAt)
            hasher.combine(workout.endedAt)
            hasher.combine(workout.updatedAt)
            hasher.combine(workout.totalVolume)
            // Do not touch relationship counts here. On a cold SwiftData
            // graph even `.count` can fault/materialize hundreds of child
            // collections on the MainActor. All nested authored mutations
            // cross a terminal save boundary that stamps this parent clock.
        }
        hasher.combine(ended)
        return String(hasher.finalize())
    }

    /// Fingerprint that also invalidates when Apple Health recovery data
    /// refreshes — required for anything feeding `RecoveryEngine`.
    @MainActor
    static func withHealth(_ workouts: [WorkoutModel]) -> String {
        let store = HealthMetricsStore.shared
        let metrics = store.metrics
        let latestMetric = metrics.last?.date.timeIntervalSince1970 ?? 0
        return of(workouts) + "|\(metrics.count)|\(latestMetric)|\(store.metricsRevision)"
    }
}
