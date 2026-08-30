import ForgeCore
import Foundation

/// Heart-rate recovery for one *recovery unit* — a span of work with no rest
/// inside it — derived post-hoc from a workout's HealthKit HR series and the
/// completion timestamps of the sets in that span.
struct SetRecoveryPoint: Equatable, Identifiable {
    /// Every set in the unit, in completion order. The last element is the leg
    /// the rest actually followed; a straight set is a unit of one.
    let setIDs: [UUID]
    /// Peak bpm reached across the whole unit (absorbs optical-sensor lag — HR
    /// usually peaks a beat after the work finishes).
    let peakHR: Int
    /// How many bpm HR fell during the rest that followed the unit, before the
    /// next effort. `nil` when the heart-rate curve doesn't show at least
    /// `minimumRestObservation` of rest. Larger = faster recovery.
    let recoveryBPM: Int?
    /// How much further HR climbed across a multi-set unit, from the peak of
    /// its opening set to the peak of the whole unit. This is the signal a
    /// superset or drop round actually carries — cumulative cardiovascular
    /// cost of the round — in place of a recovery reading it can't have.
    /// `nil` for single-set units.
    let withinUnitRise: Int?
    /// Seconds from the unit's last set to the HR trough — how much rest the
    /// heart-rate curve actually shows, as opposed to elapsed clock time to the
    /// next logged completion. `nil` whenever `recoveryBPM` is.
    let restObservedSeconds: Int?

    var id: UUID { setIDs.first ?? UUID() }
}

/// One completed set, flattened to the fields that decide unit boundaries.
/// A pure value type so unit grouping stays testable without SwiftData.
struct RecoverySetInput: Equatable {
    let id: UUID
    /// `WorkoutExerciseModel.id` — the logging row, not the library exercise.
    let exerciseID: UUID
    let supersetGroup: Int?
    let setType: SetType
    /// Order within its own exercise; drives the logical round index.
    let position: Int
    let completedAt: Date
}

/// Computes between-round HR recovery from a heart-rate series plus completed
/// sets. Pure value-type math — no HealthKit, no SwiftData — so it stays
/// trivially testable and can run at view time on already-loaded samples.
///
/// Why *recovery between rounds* and not "HR during the set": HR is a poor
/// proxy for lifting intensity (a heavy triple can read lower than a light set
/// of 20), but how far HR drops during rest is useful strength-session
/// recovery context.
///
/// Why the *round* and not the set: rest does not follow every set. A superset
/// leg flows straight into its partner and a drop set flows straight into the
/// next drop, so attributing a rest to either one describes work that never
/// happened. The rest of the app already models this —
/// `SupersetRoundPolicy.isRoundSatisfied` gates group rest on the round, and
/// `SetType.defaultRestSeconds` is nil for drops — so recovery is measured
/// once per unit of uninterrupted work.
enum SetHRRecovery {
    /// A trough that arrives sooner than this after the work ended is a
    /// transition, not a rest, so it produces no reading.
    private static let minimumObservation: TimeInterval = 60

    /// - Parameters:
    ///   - samples: per-sample HR series for the whole workout window, any order.
    ///   - sets: completed sets, any order — grouped into recovery units and
    ///     sorted chronologically internally.
    ///   - lastSetWindow: rest window used for the final unit, which has no
    ///     following effort to bound it.
    ///   - maxRestWindow: ceiling on how far past a unit the trough is hunted.
    ///     A twenty-minute phone break would otherwise report the drop to
    ///     resting HR as if it were between-set recovery.
    ///   - maxRoundSpan: how far apart two legs of the same logical round may
    ///     be completed and still be measured as one span. Beyond this the
    ///     later leg stays a member of the round but is treated as a late tick
    ///     rather than late work.
    ///   - minimumRestObservation: how much rest the HR curve must actually
    ///     show before a drop is reported.
    ///   - peakLookback / peakLookahead: how far around a unit's bounds to
    ///     search for the effort's peak HR.
    static func analyze(
        samples: [(date: Date, bpm: Int)],
        sets: [RecoverySetInput],
        lastSetWindow: TimeInterval = 90,
        maxRestWindow: TimeInterval = 300,
        maxRoundSpan: TimeInterval = 240,
        minimumRestObservation: TimeInterval = minimumObservation,
        peakLookback: TimeInterval = 10,
        peakLookahead: TimeInterval = 20
    ) -> [SetRecoveryPoint] {
        guard !samples.isEmpty, !sets.isEmpty else { return [] }
        let series = samples.sorted { $0.date < $1.date }
        let units = recoveryUnits(from: sets)

        var points: [SetRecoveryPoint] = []
        for (index, unit) in units.enumerated() {
            guard let first = unit.first else { continue }
            // Members are structural; the measured span is not. A leg ticked
            // long after the round was performed still belongs to the round —
            // it just can't stretch the window, or the "round" would swallow
            // every set in between and read a nonsense peak.
            let unitStart = first.completedAt
            let spanned = unit.prefix {
                $0.completedAt.timeIntervalSince(unitStart) <= maxRoundSpan
            }
            guard let last = spanned.last else { continue }
            let unitEnd = last.completedAt

            // Peak of the whole round, anchored on its bounds with a
            // lag-absorbing window. Taking each leg's local peak would
            // understate a round whose HR tops out during a later leg.
            guard let peak = maxBPM(
                in: series,
                from: unitStart.addingTimeInterval(-peakLookback),
                to: unitEnd.addingTimeInterval(peakLookahead)
            ) else {
                continue // No HR near this round — manual/no-watch work.
            }

            // Rest runs from the peak until the next effort. The next unit's
            // *first* completion is the earliest proof that work resumed —
            // using its last completion would let the window swallow a whole
            // superset round.
            // Rest begins when the unit's work ends, not when its peak
            // occurred. A superset round often peaks on its *first* leg, and
            // hunting from there would put the transition between legs — and
            // the whole second leg — inside the "rest" window. The dip between
            // legs is then free to be the window minimum, which lands the
            // trough before the round even finished and silently voids the
            // reading.
            let restStart = max(peak.date, unitEnd)
            let isFinal = index + 1 == units.count
            let searchEnd: Date = isFinal
                ? restStart.addingTimeInterval(lastSetWindow)
                : min(units[index + 1][0].completedAt, unitEnd.addingTimeInterval(maxRestWindow))
            let restSamples = series.filter { $0.date > restStart && $0.date <= searchEnd }

            var recovery: Int?
            var restObserved: Int?
            if let trough = restSamples.min(by: { $0.bpm < $1.bpm }) {
                let secondsToTrough = trough.date.timeIntervalSince(unitEnd)
                // Elapsed time to the next logged completion is not evidence of
                // rest: performing the next set can take 45 seconds on its own,
                // so a superset leg clears any clock-based gate while the lifter
                // rested for none of it. Interior rest ends where HR turns back
                // up toward the next effort, so the trough is what proves the
                // rest happened. A final unit has no following effort to
                // truncate its window, so observing the window is enough — HR
                // that never fell there is a real zero-drop reading.
                let proven = isFinal
                    ? restSamples.contains { $0.date >= unitEnd.addingTimeInterval(minimumRestObservation) }
                    : secondsToTrough >= minimumRestObservation
                if proven {
                    recovery = max(0, peak.bpm - trough.bpm)
                    restObserved = Int(max(0, secondsToTrough).rounded())
                }
            }

            var rise: Int?
            if spanned.count > 1,
               let opening = maxBPM(
                   in: series,
                   from: unitStart.addingTimeInterval(-peakLookback),
                   to: unitStart.addingTimeInterval(peakLookahead)
               ) {
                rise = max(0, peak.bpm - opening.bpm)
            }

            points.append(
                SetRecoveryPoint(
                    setIDs: unit.map(\.id),
                    peakHR: peak.bpm,
                    recoveryBPM: recovery,
                    withinUnitRise: rise,
                    restObservedSeconds: restObserved
                )
            )
        }
        return points
    }

    /// Splits completed sets into rounds of uninterrupted work.
    ///
    /// Grouping is **structural, not chronological**: a round is defined by the
    /// plan (which superset group, which logical round), never by tick order.
    /// `completedAt` records when the checkbox was tapped, not when the set was
    /// performed — a lifter who finishes a superset round but only ticks the
    /// second leg at the end of the session would otherwise have that round
    /// torn into two orphan sets minutes apart. Superset group numbers are
    /// unique within a workout (`SupersetUI.nextGroup(excluding:)`), so the
    /// group alone is a safe key.
    ///
    /// Units come back sorted by their first completion, members sorted within.
    static func recoveryUnits(from sets: [RecoverySetInput]) -> [[RecoverySetInput]] {
        let rounds = logicalRounds(in: sets)
        var buckets: [UnitKey: [RecoverySetInput]] = [:]
        for set in sets {
            guard let round = rounds[set.id] else { continue }
            let key: UnitKey = set.supersetGroup.map { .superset(group: $0, round: round) }
                ?? .straight(exercise: set.exerciseID, round: round)
            buckets[key, default: []].append(set)
        }
        return buckets.values
            .map { $0.sorted { $0.completedAt < $1.completedAt } }
            .sorted { ($0.first?.completedAt ?? .distantPast) < ($1.first?.completedAt ?? .distantPast) }
    }

    /// A drop set never advances the round, so it lands in the same bucket as
    /// the set it hangs off — the drop chain needs no rule of its own.
    private enum UnitKey: Hashable {
        case superset(group: Int, round: Int)
        case straight(exercise: UUID, round: Int)
    }

    /// Logical round per set, counted within its own exercise. Drop sets hang
    /// off the set above them and never advance the round, so unequal drop
    /// chains don't shift one superset member out of step with another —
    /// the same rule `SupersetRoundPolicy` applies while logging.
    private static func logicalRounds(in sets: [RecoverySetInput]) -> [UUID: Int] {
        var rounds: [UUID: Int] = [:]
        for (_, rows) in Dictionary(grouping: sets, by: \.exerciseID) {
            var round = -1
            for row in rows.sorted(by: { $0.position < $1.position }) {
                if row.setType != .drop { round += 1 }
                rounds[row.id] = max(0, round)
            }
        }
        return rounds
    }

    private static func maxBPM(
        in series: [(date: Date, bpm: Int)],
        from start: Date,
        to end: Date
    ) -> (date: Date, bpm: Int)? {
        series.filter { $0.date >= start && $0.date <= end }.max { $0.bpm < $1.bpm }
    }
}
