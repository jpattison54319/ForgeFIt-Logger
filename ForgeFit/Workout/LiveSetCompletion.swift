import ForgeCore
import ForgeData
import Foundation

/// Establishes every metric input a completed row needs before live counters
/// and personal-record awards are refreshed.
enum LiveSetCompletion {
    static func prepare(
        _ set: SetModel,
        completedAt: Date,
        exerciseWeightMode: WeightMode? = nil,
        latestBodyweight: Double?
    ) {
        set.completedAt = completedAt
        captureBodyweight(for: set, exerciseWeightMode: exerciseWeightMode, latestBodyweight: latestBodyweight)
        set.recomputeDerivedMetrics()
    }

    @discardableResult
    static func captureBodyweight(
        for set: SetModel, exerciseWeightMode: WeightMode?, latestBodyweight: Double?
    ) -> Bool {
        var changed = false
        if set.weightMode == .external, exerciseWeightMode == .bodyweight,
           (set.weight ?? 0) == 0, (set.implementWeight ?? 0) == 0 {
            set.weightMode = .bodyweight
            changed = true
        }
        if set.weightMode != .external, set.bodyweightKg == nil,
           let latestBodyweight, latestBodyweight.isFinite, latestBodyweight > 0 {
            set.bodyweightKg = latestBodyweight
            changed = true
        }
        return changed
    }
}
