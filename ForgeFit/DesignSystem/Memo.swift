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
/// O(workouts) with no per-set work: counts, the newest `updatedAt`, and the
/// stored per-workout volume rollup together move whenever a workout is
/// added, finished, deleted, edited, or a set completion changes its volume.
enum AnalyticsFingerprint {
    static func of(_ workouts: [WorkoutModel]) -> String {
        var live = 0
        var ended = 0
        var latestUpdate = Date.distantPast
        var volumeSum = 0.0
        for workout in workouts where workout.deletedAt == nil {
            live += 1
            if workout.endedAt != nil { ended += 1 }
            if workout.updatedAt > latestUpdate { latestUpdate = workout.updatedAt }
            volumeSum += workout.totalVolume ?? 0
        }
        return "\(live)|\(ended)|\(latestUpdate.timeIntervalSince1970)|\(volumeSum)"
    }

    /// Fingerprint that also invalidates when Apple Health recovery data
    /// refreshes — required for anything feeding `RecoveryEngine`.
    @MainActor
    static func withHealth(_ workouts: [WorkoutModel]) -> String {
        let metrics = HealthMetricsStore.shared.metrics
        let latestMetric = metrics.last?.date.timeIntervalSince1970 ?? 0
        return of(workouts) + "|\(metrics.count)|\(latestMetric)"
    }
}
