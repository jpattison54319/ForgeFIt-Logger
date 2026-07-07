import Foundation

/// The training discipline an exercise belongs to. Historically the app only
/// distinguished strength from cardio via `ExerciseLibraryModel.isCardio`;
/// `Modality` generalizes that without migrating existing rows — persisted as
/// an additive-optional `modalityRaw` string that, when nil, falls back to the
/// legacy `isCardio` flag (see `ExerciseLibraryModel.modality`).
public enum Modality: String, Codable, CaseIterable, Sendable {
    case strength
    case cardio
    case yoga
}

/// The style of a yoga flow/session. Restorative styles are treated as
/// recovery-supporting activity (no training strain, reduced XP rate);
/// active styles count like light training.
///
/// Lives in ForgeCore (unlike `CardioKind`, an app-target type) because it
/// rides inside `YogaFlowPlan` JSON that both the phone and the watch decode.
public enum YogaStyle: String, Codable, CaseIterable, Sendable {
    case vinyasa
    case hatha
    case power
    case yin
    case restorative
    case gentle

    /// Recovery-oriented styles: long passive holds, parasympathetic focus.
    /// Everything else is an active practice that accrues training load.
    public var isRestorative: Bool {
        switch self {
        case .yin, .restorative, .gentle: return true
        case .vinyasa, .hatha, .power: return false
        }
    }

    public var title: String {
        switch self {
        case .vinyasa: return "Vinyasa"
        case .hatha: return "Hatha"
        case .power: return "Power"
        case .yin: return "Yin"
        case .restorative: return "Restorative"
        case .gentle: return "Gentle"
        }
    }
}

/// A guided yoga sequence: an ordered list of timed pose holds. The yoga
/// sibling of `IntervalPlan` — deliberately a separate type because a pose
/// step carries pose identity, side, and cue info that would contaminate the
/// cardio interval editor/runner if grafted onto `IntervalPlan.Step`.
///
/// Stored as JSON on `RoutineExerciseModel.yogaFlowJSON` (template),
/// `WorkoutExerciseModel.yogaFlowJSON` (per-workout snapshot), and
/// `YogaFlowModel.planJSON` (user-saved flows); lives in ForgeCore so both
/// the phone (execution authority) and the watch (display mirror) decode the
/// same shape.
public struct YogaFlowPlan: Codable, Equatable, Sendable {
    public struct PoseStep: Codable, Equatable, Sendable, Identifiable {
        public var id: UUID
        /// `ExerciseLibraryModel.id` of the pose (deterministic for seeded poses).
        public var poseID: UUID
        /// Catalog slug for cue/illustration lookup; nil for custom poses.
        public var poseSlug: String?
        /// Denormalized display name so the watch and player render without a
        /// database round-trip.
        public var name: String
        public var holdSeconds: Int
        /// nil = bilateral pose held once; `.bothSides` expands to L then R at
        /// runtime (each held `holdSeconds`).
        public var side: Side?
        /// Author override for the spoken transition cue; nil = catalog default.
        public var transitionCue: String?

        public init(
            id: UUID = UUID(),
            poseID: UUID,
            poseSlug: String? = nil,
            name: String,
            holdSeconds: Int,
            side: Side? = nil,
            transitionCue: String? = nil
        ) {
            self.id = id
            self.poseID = poseID
            self.poseSlug = poseSlug
            self.name = name
            self.holdSeconds = holdSeconds
            self.side = side
            self.transitionCue = transitionCue
        }
    }

    public enum Side: String, Codable, Sendable {
        case left, right, bothSides

        /// Forward compatibility: a side raw value from a future app version
        /// must not fail the WHOLE plan's decode (unlike `styleRaw`, `Side`
        /// is an enum field). Unknown values fall back to `.bothSides` — the
        /// safe reading for any one-sided variant we don't know yet.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Side(rawValue: raw) ?? .bothSides
        }
    }

    public var styleRaw: String
    public var steps: [PoseStep]

    public init(style: YogaStyle, steps: [PoseStep]) {
        self.styleRaw = style.rawValue
        self.steps = steps
    }

    public init(styleRaw: String, steps: [PoseStep]) {
        self.styleRaw = styleRaw
        self.steps = steps
    }

    public var style: YogaStyle { YogaStyle(rawValue: styleRaw) ?? .hatha }

    /// Total guided duration; `.bothSides` steps count double because they
    /// expand into two holds at runtime.
    public var totalSeconds: Int {
        steps.reduce(0) { total, step in
            total + step.holdSeconds * (step.side == .bothSides ? 2 : 1)
        }
    }

    public var hasSteps: Bool { !steps.isEmpty }

    /// Number of holds the runner will actually walk through (side expansion
    /// applied).
    public var expandedStepCount: Int {
        steps.reduce(0) { $0 + ($1.side == .bothSides ? 2 : 1) }
    }

    /// "12 poses · 18min" — the compact shape used on goal rows and flow lists.
    public var structureSummary: String {
        guard hasSteps else { return "Open" }
        let poses = steps.count
        return "\(poses) pose\(poses == 1 ? "" : "s") · \(Self.shortDuration(totalSeconds))"
    }

    private static func shortDuration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m > 0 && s > 0 { return "\(m)min \(s)s" }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }

    // MARK: - JSON persistence

    public func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(from json: String?) -> YogaFlowPlan? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(YogaFlowPlan.self, from: data)
    }
}
