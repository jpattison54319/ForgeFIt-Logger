import Foundation

/// Single source of truth for load / tonnage / e1RM resolution.
///
/// This is intentionally pure and deterministic so it can be unit-tested with
/// golden vectors. All math is computed on-device — there is no server-side
/// computation to diverge from.
public enum VolumeMath {

    /// The resolved per-rep load for a set, after applying weight mode and the
    /// unilateral rule. For unilateral work this is the load on ONE limb (the
    /// implement weight); the limb count is applied later in `tonnage`.
    public static func effectiveLoad(_ s: SetEntry) -> Double {
        switch s.weightMode {
        case .external:
            return s.isUnilateral ? (s.implementWeight ?? 0) : (s.weight ?? 0)
        case .bodyweight:
            return s.bodyweightKg ?? 0
        case .bodyweightAdded:
            return (s.bodyweightKg ?? 0) + (s.addedWeight ?? 0)
        case .bodyweightAssisted:
            return max(0, (s.bodyweightKg ?? 0) - (s.assistanceWeight ?? 0))
        }
    }

    /// Effective rep count for tonnage. Full reps count 1.0; partial reps count
    /// 0.5 each (half-weighted), consistent with the muscle-volume convention.
    public static func effectiveReps(_ s: SetEntry) -> Double {
        let full = Double(s.reps ?? 0)
        let partials = Double(s.partialReps ?? 0) * 0.5
        return full + partials
    }

    /// True working tonnage for a set: load × effective reps × limbs.
    /// For unilateral work both limbs are counted (the user only ever enters
    /// one implement's weight), so historical volume is correct without the
    /// user doubling anything manually.
    public static func tonnage(_ s: SetEntry) -> Double {
        guard s.setType.countsAsWorkingVolume else { return 0 }
        let limbs = s.isUnilateral ? Double(s.limbCount) : 1.0
        return effectiveLoad(s) * effectiveReps(s) * limbs
    }

    /// Estimated 1RM via the Epley formula. Uses full reps only (partials are
    /// not part of a true 1RM estimate). Returns nil when reps are missing.
    /// The formula is a documented, versioned choice (Epley); swapping it is a
    /// deliberate decision requiring a golden-vector update.
    public static func estimated1RM(_ s: SetEntry) -> Double? {
        guard let reps = s.reps, reps > 0 else { return nil }
        let load = effectiveLoad(s)
        guard load > 0 else { return nil }
        return load * (1.0 + Double(reps) / 30.0)
    }

    /// How many "sets" a logged set is worth for dose tracking, in units of
    /// the straight-set-near-failure the weekly-volume dose-response
    /// literature counts. A documented, versioned convention — changing any
    /// weight is a deliberate decision requiring a golden-vector update:
    ///
    /// - Warm-up: 0 (not working volume).
    /// - Working / back-off / AMRAP: 1 — the literature's unit.
    /// - Drop: 0.5 per drop row. Drop-set training produces hypertrophy
    ///   comparable to traditional sets in roughly half the time (Sødal et
    ///   al. 2023 systematic review) — parent(1) + 0.5 per drop, not a full
    ///   set per drop.
    /// - Myo-rep / rest-pause: 1 for the activation + 0.5 per mini-set. Each
    ///   mini re-enters near-failure territory after seconds of rest (its
    ///   reps are all "effective reps"), but at 2–5 reps it carries roughly
    ///   half a straight set's stimulating volume. A 6+3+3+2+2 block ⇒ 3.0
    ///   sets, matching the method's empirical "≈3 sets in less time"
    ///   positioning (Prestes et al. 2019, rest-pause vs traditional).
    /// - Cluster: 1 regardless of segments — intra-set rest there preserves
    ///   bar speed within ONE set (Tufano et al. 2017); it doesn't add
    ///   near-failure episodes.
    /// - Unilateral per-side logging doubles the structure (each side is its
    ///   own activation + minis / its own cluster).
    public static func effectiveSetCount(_ s: SetEntry) -> Double {
        switch s.setType {
        case .warmup:
            return 0
        case .drop:
            return 0.5
        case .myoRep, .restPause:
            var count = 1.0 + 0.5 * Double(s.miniSetCount)
            if s.side2Logged {
                count += 1.0 + 0.5 * Double(s.side2MiniSetCount)
            }
            return count
        case .cluster:
            return s.side2Logged ? 2 : 1
        case .working, .backoff, .amrap:
            return 1
        }
    }
}
