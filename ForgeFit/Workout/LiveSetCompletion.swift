import ForgeCore
import ForgeData
import Foundation

/// Establishes every metric input a completed row needs before live counters
/// and personal-record awards are refreshed.
enum LiveSetCompletion {
    static func prepare(
        _ set: SetModel,
        completedAt: Date,
        latestBodyweight: Double?
    ) {
        set.completedAt = completedAt
        if set.weightMode != .external,
           set.bodyweightKg == nil,
           let latestBodyweight {
            set.bodyweightKg = latestBodyweight
        }
        set.recomputeDerivedMetrics()
    }
}
