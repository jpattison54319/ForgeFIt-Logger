import Foundation

/// Between-set heart-rate recovery for a single strength set, derived post-hoc
/// from a workout's HealthKit HR series and the set's completion timestamp.
struct SetRecoveryPoint: Equatable {
    let setID: UUID
    /// Peak bpm reached around the end of the set (absorbs optical-sensor lag —
    /// HR usually peaks a beat after the set finishes).
    let peakHR: Int
    /// How many bpm the HR fell during the rest that followed, before the next
    /// set's effort. `nil` when there's no rest window to measure (e.g. the HR
    /// series ends right after the set). Larger = faster recovery.
    let recoveryBPM: Int?
}

/// Computes between-set HR recovery from a heart-rate series plus set completion
/// timestamps. Pure value-type math — no HealthKit, no SwiftData — so it stays
/// trivially testable and can run at view time on already-loaded samples.
///
/// Why *recovery between sets* and not "HR during the set": HR is a poor proxy
/// for lifting intensity (a heavy triple can read lower than a light set of 20),
/// but how far HR drops during rest is a real conditioning/readiness signal.
enum SetHRRecovery {

    /// - Parameters:
    ///   - samples: per-sample HR series for the whole workout window, any order.
    ///   - sets: completed strength sets as `(id, completedAt)`, any order — the
    ///     function sorts them chronologically so recovery is measured to the
    ///     next set in time (correct even for interleaved supersets).
    ///   - lastSetWindow: rest window used for the final set, which has no
    ///     "next set" bound.
    ///   - peakLookback / peakLookahead: how far around a set's `completedAt` to
    ///     search for the effort's peak HR.
    static func analyze(
        samples: [(date: Date, bpm: Int)],
        sets: [(id: UUID, completedAt: Date)],
        lastSetWindow: TimeInterval = 90,
        peakLookback: TimeInterval = 10,
        peakLookahead: TimeInterval = 20
    ) -> [SetRecoveryPoint] {
        guard !samples.isEmpty, !sets.isEmpty else { return [] }
        let series = samples.sorted { $0.date < $1.date }
        let ordered = sets.sorted { $0.completedAt < $1.completedAt }

        var points: [SetRecoveryPoint] = []
        for (index, set) in ordered.enumerated() {
            let t = set.completedAt
            // Peak of the effort, anchored on completion with a lag-absorbing window.
            let peakStart = t.addingTimeInterval(-peakLookback)
            let peakEnd = t.addingTimeInterval(peakLookahead)
            let peakWindow = series.filter { $0.date >= peakStart && $0.date <= peakEnd }
            guard let peak = peakWindow.max(by: { $0.bpm < $1.bpm }) else {
                continue // No HR near this set — manual/no-watch set.
            }

            // Rest window runs from the peak to the next set's completion (or a
            // fixed window for the last set). The min over that span is the rest
            // trough — how far HR came down before the next effort.
            let restEnd: Date = index + 1 < ordered.count
                ? ordered[index + 1].completedAt
                : peak.date.addingTimeInterval(lastSetWindow)
            let recovery: Int?
            if restEnd > peak.date,
               let trough = series
                   .filter({ $0.date > peak.date && $0.date <= restEnd })
                   .min(by: { $0.bpm < $1.bpm }) {
                recovery = max(0, peak.bpm - trough.bpm)
            } else {
                recovery = nil
            }
            points.append(SetRecoveryPoint(setID: set.id, peakHR: peak.bpm, recoveryBPM: recovery))
        }
        return points
    }
}
