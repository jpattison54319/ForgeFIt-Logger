import Foundation

/// Deterministic, evidence-based yoga sequencing: turns a pose catalog plus a
/// style/duration/difficulty request into a `YogaFlowPlan`.
///
/// The sequencing follows the classical class arc taught across lineages
/// (Iyengar's sequencing principles, common vinyasa krama): warm-up first to
/// raise tissue temperature → standing/balance work while the nervous system
/// is fresh → peak effort (backbends, core, inversions) → floor unwind
/// (hip openers, forward folds, twists) to down-regulate → ALWAYS a resting
/// closer (savasana-like) because the parasympathetic rebound is where the
/// recovery benefit accrues. The closer's hold absorbs whatever time the body
/// of the class didn't consume, so the plan lands exactly on target without
/// ever truncating the rest.
///
/// Lives in ForgeCore (not the app target) so both the phone and the watch
/// can regenerate/preview flows from the same pure function, and because it
/// must stay decoupled from SwiftData — it takes plain `PoseInput` values,
/// not `ExerciseLibraryModel` rows.
///
/// Everything is pure and seeded: `SystemRandomNumberGenerator` is banned
/// here because a regenerated plan must be reproducible for sync/debugging
/// (same request = byte-identical plan on phone and watch).
public enum YogaFlowGenerator {

    // MARK: - Inputs

    /// The functional family a pose belongs to. Drives arc placement, not
    /// display — a pose can look like several things but is slotted where its
    /// primary training effect sits in the class arc.
    public enum Category: String, Codable, CaseIterable, Sendable {
        case warmup
        case standing
        case balance
        case backbend
        case forwardFold
        case twist
        case hipOpener
        case core
        case inversion
        case resting
    }

    /// Ordered so a request difficulty acts as a ceiling: a plan never
    /// contains a pose harder than requested (safety — an unsupervised app
    /// user has no teacher to offer modifications).
    public enum Difficulty: String, Codable, CaseIterable, Sendable, Comparable {
        case beginner
        case intermediate
        case advanced

        private var rank: Int {
            switch self {
            case .beginner: return 0
            case .intermediate: return 1
            case .advanced: return 2
            }
        }

        public static func < (lhs: Difficulty, rhs: Difficulty) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    /// Catalog-shaped pose description. Deliberately not the SwiftData model:
    /// keeps the generator testable and watch-safe.
    public struct PoseInput: Sendable, Equatable {
        public var slug: String
        public var poseID: UUID
        public var name: String
        public var category: Category
        public var difficulty: Difficulty
        /// True for poses practiced one side at a time (Warrior II, Tree…).
        /// These are emitted with `side = .bothSides`, so the runtime doubles
        /// them — the generator budgets 2x their hold accordingly.
        public var unilateral: Bool
        public var defaultHoldSeconds: Int

        public init(
            slug: String,
            poseID: UUID,
            name: String,
            category: Category,
            difficulty: Difficulty,
            unilateral: Bool = false,
            defaultHoldSeconds: Int
        ) {
            self.slug = slug
            self.poseID = poseID
            self.name = name
            self.category = category
            self.difficulty = difficulty
            self.unilateral = unilateral
            self.defaultHoldSeconds = defaultHoldSeconds
        }
    }

    public struct Request: Sendable, Equatable {
        public var style: YogaStyle
        public var targetMinutes: Int
        public var difficulty: Difficulty
        /// Explicit seed instead of ambient randomness so regenerating with
        /// the same inputs reproduces the exact same plan (see type docs).
        public var seed: UInt64

        public init(style: YogaStyle, targetMinutes: Int, difficulty: Difficulty, seed: UInt64) {
            self.style = style
            self.targetMinutes = targetMinutes
            self.difficulty = difficulty
            self.seed = seed
        }
    }

    // MARK: - Generation

    /// Builds a plan hitting `targetMinutes` within ±10% (in practice exactly,
    /// because the resting closer absorbs the remainder). Returns nil when the
    /// catalog can't satisfy the template — most importantly when no resting
    /// pose survives the difficulty filter, because a flow without a resting
    /// closer is not a class we're willing to generate.
    public static func generate(request: Request, poses: [PoseInput]) -> YogaFlowPlan? {
        let targetSeconds = request.targetMinutes * 60
        let restingReserve = Self.restingReserve(for: request.style)
        // Too short to even fit the style's minimum resting closer.
        guard targetSeconds >= restingReserve else { return nil }

        // Difficulty is a ceiling, never a floor: beginners get only beginner
        // poses; advanced requests may still draw easy poses (real classes do).
        let eligible = poses.filter { $0.difficulty <= request.difficulty }

        var rng = SplitMix64(seed: request.seed)

        // Shuffle within each category group (in fixed declaration order so
        // RNG consumption — and therefore the whole plan — is deterministic).
        var grouped: [Category: [PoseInput]] = [:]
        for category in Category.allCases {
            let members = eligible.filter { $0.category == category }
            grouped[category] = members.shuffled(using: &rng)
        }

        guard let restingPose = Self.pickRestingPose(from: grouped[.resting] ?? []) else {
            return nil
        }

        let bodyBudget = targetSeconds - restingReserve
        var steps: [YogaFlowPlan.PoseStep] = []
        var bodyTotal = 0
        var lastSlug: String? = nil

        for phase in Self.phases(for: request.style) {
            // Interleave by category order within the phase, poses already
            // shuffled inside their groups.
            let candidates = phase.categories.flatMap { grouped[$0] ?? [] }
            guard !candidates.isEmpty else { continue }

            let phaseBudget = Int(Double(bodyBudget) * phase.weight)
            var phaseTotal = 0
            var index = 0
            var stalls = 0
            // Cycle through the phase's candidates until its time budget is
            // spent. Reuse (duplicates) is allowed — small catalogs must still
            // fill long classes — but never the same slug twice in a row.
            // A full lap with no successful append terminates the phase.
            while phaseTotal < phaseBudget && stalls < candidates.count {
                let pose = candidates[index % candidates.count]
                index += 1
                let hold = Self.adjustedHold(for: pose, style: request.style)
                let cost = hold * (pose.unilateral ? 2 : 1)
                guard pose.slug != lastSlug, phaseTotal + cost <= phaseBudget else {
                    stalls += 1
                    continue
                }
                steps.append(Self.step(for: pose, holdSeconds: hold, rng: &rng))
                phaseTotal += cost
                bodyTotal += cost
                lastSlug = pose.slug
                stalls = 0
            }
        }

        // The resting closer absorbs all remaining time so the plan lands
        // exactly on target. It is never truncated below the style reserve —
        // shortening savasana to fit is exactly the mistake human teachers
        // make under time pressure, and we refuse to reproduce it.
        let restingHold = targetSeconds - bodyTotal
        var closer = Self.step(for: restingPose, holdSeconds: restingHold, rng: &rng)
        // Held once regardless of laterality: the closer is one continuous
        // down-regulation block, not a per-side exercise.
        closer.side = nil
        steps.append(closer)

        return YogaFlowPlan(style: request.style, steps: steps)
    }

    // MARK: - Style templates

    private struct Phase {
        let categories: [Category]
        /// Fraction of the non-resting time budget this phase may consume.
        let weight: Double
    }

    /// Classical arc per style. Yin/restorative/gentle skip the standing arc
    /// entirely — those practices are floor-based by definition (long passive
    /// holds targeting connective tissue / parasympathetic tone), so only
    /// hip openers, forward folds, and resting shapes are legal.
    private static func phases(for style: YogaStyle) -> [Phase] {
        switch style {
        case .yin, .restorative, .gentle:
            return [
                Phase(categories: [.hipOpener, .forwardFold], weight: 1.0)
            ]
        case .power:
            // Power biases toward the strength categories (standing, balance,
            // core) with a heavier peak and a short unwind.
            return [
                Phase(categories: [.warmup], weight: 0.10),
                Phase(categories: [.standing, .balance], weight: 0.35),
                Phase(categories: [.core, .inversion, .backbend], weight: 0.35),
                Phase(categories: [.hipOpener, .forwardFold, .twist], weight: 0.20)
            ]
        case .hatha, .vinyasa:
            return [
                Phase(categories: [.warmup], weight: 0.15),
                Phase(categories: [.standing, .balance], weight: 0.30),
                Phase(categories: [.backbend, .core, .inversion], weight: 0.25),
                Phase(categories: [.hipOpener, .forwardFold, .twist], weight: 0.30)
            ]
        }
    }

    /// Style-appropriate hold windows. Yin holds 2–5 minutes (the tissue
    /// argument: fascia only responds to long loading), restorative 90–180s,
    /// power keeps holds short and metabolic, hatha holds longer than vinyasa
    /// because vinyasa links poses breath-to-movement.
    private static func adjustedHold(for pose: PoseInput, style: YogaStyle) -> Int {
        let base = pose.defaultHoldSeconds
        switch style {
        case .yin: return min(max(base, 120), 300)
        case .restorative, .gentle: return min(max(base, 90), 180)
        case .power: return min(max(base * 3 / 4, 15), 45)
        case .vinyasa: return min(max(base, 20), 60)
        case .hatha: return min(max(base, 30), 90)
        }
    }

    /// Minimum seconds reserved for the resting closer. Longer for the
    /// restorative styles because a sub-2-minute "long hold" contradicts the
    /// entire premise of the practice.
    private static func restingReserve(for style: YogaStyle) -> Int {
        switch style {
        case .yin: return 120
        case .restorative, .gentle: return 90
        case .hatha, .vinyasa, .power: return 60
        }
    }

    /// Prefer a bilateral resting pose for the closer; groups are already
    /// seeded-shuffled so "first" is deterministic per seed.
    private static func pickRestingPose(from shuffledResting: [PoseInput]) -> PoseInput? {
        shuffledResting.first(where: { !$0.unilateral }) ?? shuffledResting.first
    }

    private static func step(
        for pose: PoseInput,
        holdSeconds: Int,
        rng: inout SplitMix64
    ) -> YogaFlowPlan.PoseStep {
        YogaFlowPlan.PoseStep(
            id: rng.nextUUID(),
            poseID: pose.poseID,
            poseSlug: pose.slug,
            name: pose.name,
            holdSeconds: holdSeconds,
            side: pose.unilateral ? .bothSides : nil,
            transitionCue: nil
        )
    }
}

// MARK: - Seeded RNG

/// SplitMix64 (Steele/Lea/Flood 2014): tiny, well-distributed, and — unlike
/// `SystemRandomNumberGenerator` — reproducible from a seed, which the
/// generator's determinism contract requires. Internal so other ForgeCore
/// generators can reuse it, but not part of the public API surface.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Deterministic UUIDs for generated step ids: makes two plans from the
    /// same seed compare equal via `YogaFlowPlan == ` (ids included), which is
    /// what sync-level reproducibility means in practice. Version/variant
    /// bits are set so the result is still a well-formed v4-shaped UUID.
    mutating func nextUUID() -> UUID {
        let a = next()
        let b = next()
        func byte(_ value: UInt64, _ index: UInt64) -> UInt8 {
            UInt8(truncatingIfNeeded: value >> (index * 8))
        }
        var bytes: [UInt8] = (0..<8).map { byte(a, $0) } + (0..<8).map { byte(b, $0) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
