import Foundation

/// A structured cardio interval template attached to a routine's cardio
/// exercise: warmup → N × (work / recover) → cooldown. Time-based steps only
/// (v1) — the runner counts each step down and auto-advances.
///
/// Stored as JSON on `RoutineExerciseModel.intervalPlanJSON`; lives in
/// ForgeCore so both the phone (execution authority) and the watch (display
/// mirror) decode the same shape.
public struct IntervalPlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            case warmup, work, recover, cooldown
        }

        public var id: UUID
        public var kind: Kind
        public var seconds: Int
        /// Display label, e.g. "Work 3/6"; derived at expansion time.
        public var label: String
        /// Optional per-step HR target zone (1...5): the zone guard follows
        /// step transitions (work in Z4, recover in Z2). Optional so plans
        /// encoded before this existed still decode.
        public var hrZone: Int?

        public init(id: UUID = UUID(), kind: Kind, seconds: Int, label: String, hrZone: Int? = nil) {
            self.id = id
            self.kind = kind
            self.seconds = seconds
            self.label = label
            self.hrZone = hrZone
        }
    }

    public var steps: [Step]
    /// Optional HR "zone lock": the target zone (1...5) the athlete wants to
    /// hold. When set, a zone guard fires audible/haptic cues on leaving and
    /// re-entering the zone. Independent of the time-based steps — a plan can
    /// have a zone target with no steps (a pure zone-lock run). Optional so
    /// plans encoded before this existed still decode.
    public var hrZoneTarget: Int?

    public init(steps: [Step], hrZoneTarget: Int? = nil) {
        self.steps = steps
        self.hrZoneTarget = hrZoneTarget
    }

    public var totalSeconds: Int {
        steps.reduce(0) { $0 + $1.seconds }
    }

    public var hasSteps: Bool { !steps.isEmpty }
    /// Whether this plan carries anything worth persisting/running.
    public var isMeaningful: Bool { hasSteps || hrZoneTarget != nil }

    /// Builder used by the plan editor: expands a repeat structure into the
    /// flat step list that gets persisted and executed.
    public static func build(
        warmupSeconds: Int,
        repeats: Int,
        workSeconds: Int,
        recoverSeconds: Int,
        cooldownSeconds: Int,
        hrZoneTarget: Int? = nil,
        workZone: Int? = nil,
        recoverZone: Int? = nil
    ) -> IntervalPlan {
        var steps: [Step] = []
        if warmupSeconds > 0 {
            steps.append(Step(kind: .warmup, seconds: warmupSeconds, label: "Warm-up"))
        }
        if repeats > 0, workSeconds > 0 {
            for round in 1...repeats {
                steps.append(Step(kind: .work, seconds: workSeconds, label: "Work \(round)/\(repeats)", hrZone: workZone))
                // No trailing recover after the last work rep — cooldown covers it.
                if recoverSeconds > 0, round < repeats {
                    steps.append(Step(kind: .recover, seconds: recoverSeconds, label: "Recover \(round)/\(repeats - 1)", hrZone: recoverZone))
                }
            }
        }
        if cooldownSeconds > 0 {
            steps.append(Step(kind: .cooldown, seconds: cooldownSeconds, label: "Cool-down"))
        }
        return IntervalPlan(steps: steps, hrZoneTarget: hrZoneTarget)
    }

    /// "6 × 1min / 1min 30s · 32min" — the compact shape used on goal rows
    /// and preset lists.
    public var structureSummary: String {
        let works = steps.filter { $0.kind == .work }
        guard let work = works.first else {
            if let zone = hrZoneTarget { return "Zone \(zone) lock" }
            return "Open"
        }
        let recover = steps.first { $0.kind == .recover }
        var text = "\(works.count) × \(Self.shortDuration(work.seconds))"
        if let recover { text += " / \(Self.shortDuration(recover.seconds))" }
        text += " · \(Self.shortDuration(totalSeconds)) total"
        return text
    }

    /// The 1-based round of a step index among the plan's work blocks, e.g.
    /// (round: 3, total: 6) while running "Work 3/6" or the recover after it.
    public func roundInfo(at index: Int) -> (round: Int, total: Int)? {
        let total = steps.filter { $0.kind == .work }.count
        guard total > 0, index < steps.count else { return nil }
        let round = steps.prefix(index + 1).filter { $0.kind == .work }.count
        guard round > 0 else { return nil }
        return (round, total)
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

    public static func decode(from json: String?) -> IntervalPlan? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IntervalPlan.self, from: data)
    }
}
