import Foundation

/// A structured cardio goal attached to a routine's cardio exercise — from a
/// single session target ("run 5 km") up to an ordered step sequence
/// (warmup → N × (work / recover) → cooldown, or any custom order).
///
/// Stored as JSON on `RoutineExerciseModel.intervalPlanJSON`; lives in
/// ForgeCore so both the phone (execution authority) and the watch (display
/// mirror) decode the same shape.
///
/// Versioning contract: every field added after v1 is optional, so plans and
/// presets encoded by older builds keep decoding. The reverse also holds —
/// older builds ignore the new keys; a distance-based step encodes
/// `seconds: 0` there, which an old runner skips instantly rather than
/// mis-times.
public struct IntervalPlan: Codable, Equatable, Sendable {
    /// A metric band a step (or the whole session) asks the athlete to hold.
    /// Bounds are in canonical units — pace: seconds per km (low = the faster
    /// bound, numerically smaller), power: watts, cadence: per minute. The
    /// semantic mapping ("ahead"/"behind" for pace) belongs to the alert
    /// layer; this type only classifies numbers against the band.
    public struct Target: Codable, Equatable, Sendable {
        public enum Metric: String, Codable, Sendable, CaseIterable {
            case pace, power, cadence
        }

        public enum Position: Equatable, Sendable {
            case below, within, above
        }

        public var metric: Metric
        public var low: Double?
        public var high: Double?

        public init(metric: Metric, low: Double? = nil, high: Double? = nil) {
            self.metric = metric
            self.low = low
            self.high = high
        }

        /// A target with no bounds is decorative, not a target.
        public var isMeaningful: Bool { low != nil || high != nil }

        public func classify(_ value: Double) -> Position {
            if let low, value < low { return .below }
            if let high, value > high { return .above }
            return .within
        }
    }

    /// A whole-session target for open (non-stepped) efforts: cover a
    /// distance, last a duration, burn calories, or climb. `value` is in the
    /// kind's canonical unit (meters / seconds / kcal / meters climbed).
    public struct SessionGoal: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case distance, duration, calories, elevation
        }

        public var kind: Kind
        public var value: Double

        public init(kind: Kind, value: Double) {
            self.kind = kind
            self.value = value
        }

        public var isMeaningful: Bool { value > 0 }

        /// Completion fraction (0...1+, uncapped above 1 so "goal beaten" is
        /// representable) for a current reading in the goal's own unit.
        public func fraction(current: Double) -> Double {
            guard value > 0 else { return 0 }
            return max(0, current / value)
        }
    }

    public struct Step: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case warmup, work, recover, cooldown
        }

        public var id: UUID
        public var kind: Kind
        /// Length of a TIMED step. A distance-based step encodes 0 here (see
        /// the versioning contract above) and carries `distanceMeters`.
        public var seconds: Int
        /// Display label, e.g. "Work 3/6"; derived at expansion time.
        public var label: String
        /// Optional per-step HR target zone (1...5): the zone guard follows
        /// step transitions (work in Z4, recover in Z2). Optional so plans
        /// encoded before this existed still decode.
        public var hrZone: Int?
        /// Non-nil makes this a DISTANCE step: it completes when the athlete
        /// covers this many meters, not when a clock runs out. The runner
        /// needs a live distance source (GPS or watch); without one it falls
        /// back to manual skip.
        public var distanceMeters: Double?
        /// Optional metric band to hold during this step (pace/power/
        /// cadence). Pace targets get live alerts when a live distance
        /// source exists; power/cadence render as guidance — ForgeFit has no
        /// live sensor for them and does not pretend otherwise.
        public var target: Target?

        public init(
            id: UUID = UUID(),
            kind: Kind,
            seconds: Int,
            label: String,
            hrZone: Int? = nil,
            distanceMeters: Double? = nil,
            target: Target? = nil
        ) {
            self.id = id
            self.kind = kind
            self.seconds = seconds
            self.label = label
            self.hrZone = hrZone
            self.distanceMeters = distanceMeters
            self.target = target
        }

        public var isDistanceBased: Bool { (distanceMeters ?? 0) > 0 }
    }

    public var steps: [Step]
    /// Optional HR "zone lock": the target zone (1...5) the athlete wants to
    /// hold. When set, a zone guard fires audible/haptic cues on leaving and
    /// re-entering the zone. Independent of the steps — a plan can have a
    /// zone target with no steps (a pure zone-lock run). Optional so plans
    /// encoded before this existed still decode.
    public var hrZoneTarget: Int?
    /// Whole-session target for open efforts ("5 km", "45 min", "400 kcal",
    /// "300 m climb"). Coexists with `hrZoneTarget` (zone 2 until 10 km) but
    /// not with steps — the builder treats steps and session goals as
    /// different shapes.
    public var goal: SessionGoal?
    /// Session-wide metric band for steady efforts ("hold 5:20–5:40 /km").
    /// Step-level targets win while a step is active.
    public var target: Target?

    public init(
        steps: [Step],
        hrZoneTarget: Int? = nil,
        goal: SessionGoal? = nil,
        target: Target? = nil
    ) {
        self.steps = steps
        self.hrZoneTarget = hrZoneTarget
        self.goal = goal
        self.target = target
    }

    /// Sum of the TIMED steps only — distance steps have no knowable
    /// duration until they're run.
    public var totalSeconds: Int {
        steps.filter { !$0.isDistanceBased }.reduce(0) { $0 + $1.seconds }
    }

    /// Sum of the distance steps' targets, 0 when the plan is fully timed.
    public var totalDistanceMeters: Double {
        steps.filter(\.isDistanceBased).reduce(0) { $0 + ($1.distanceMeters ?? 0) }
    }

    public var hasSteps: Bool { !steps.isEmpty }
    public var hasDistanceSteps: Bool { steps.contains(where: \.isDistanceBased) }
    /// Whether this plan carries anything worth persisting/running.
    public var isMeaningful: Bool {
        hasSteps
            || hrZoneTarget != nil
            || goal?.isMeaningful == true
            || target?.isMeaningful == true
    }

    /// Builder used by the repeat-structure editor: expands warmup →
    /// N × (work / recover) → cooldown into the flat step list that gets
    /// persisted and executed. Work/recover length is either timed
    /// (`workSeconds`) or distance-based (`workDistanceMeters` wins when
    /// both are passed); warmup/cooldown stay timed — nobody warms up "for
    /// 400 m" on a machine that hasn't started.
    public static func build(
        warmupSeconds: Int,
        repeats: Int,
        workSeconds: Int,
        recoverSeconds: Int,
        cooldownSeconds: Int,
        hrZoneTarget: Int? = nil,
        workZone: Int? = nil,
        recoverZone: Int? = nil,
        workDistanceMeters: Double? = nil,
        recoverDistanceMeters: Double? = nil,
        workTarget: Target? = nil
    ) -> IntervalPlan {
        var steps: [Step] = []
        if warmupSeconds > 0 {
            steps.append(Step(kind: .warmup, seconds: warmupSeconds, label: "Warm-up"))
        }
        let workIsDistance = (workDistanceMeters ?? 0) > 0
        let recoverIsDistance = (recoverDistanceMeters ?? 0) > 0
        if repeats > 0, workIsDistance || workSeconds > 0 {
            for round in 1...repeats {
                steps.append(Step(
                    kind: .work,
                    seconds: workIsDistance ? 0 : workSeconds,
                    label: "Work \(round)/\(repeats)",
                    hrZone: workZone,
                    distanceMeters: workIsDistance ? workDistanceMeters : nil,
                    target: workTarget?.isMeaningful == true ? workTarget : nil
                ))
                // No trailing recover after the last work rep — cooldown covers it.
                if recoverIsDistance || recoverSeconds > 0, round < repeats {
                    steps.append(Step(
                        kind: .recover,
                        seconds: recoverIsDistance ? 0 : recoverSeconds,
                        label: "Recover \(round)/\(repeats - 1)",
                        hrZone: recoverZone,
                        distanceMeters: recoverIsDistance ? recoverDistanceMeters : nil
                    ))
                }
            }
        }
        if cooldownSeconds > 0 {
            steps.append(Step(kind: .cooldown, seconds: cooldownSeconds, label: "Cool-down"))
        }
        return IntervalPlan(steps: steps, hrZoneTarget: hrZoneTarget)
    }

    /// Whether the steps still fit the simple repeat builder without loss:
    /// [warmup] + N × (uniform work [/ uniform recover]) + [cooldown], all
    /// timed, no step targets. Custom-ordered or distance plans open in the
    /// step-list editor instead — round-tripping them through the steppers
    /// would silently flatten them.
    public var matchesRepeatBuilderShape: Bool {
        guard hasSteps else { return true }
        guard !hasDistanceSteps, !steps.contains(where: { $0.target != nil }) else { return false }

        var index = 0
        if steps[index].kind == .warmup { index += 1 }
        var workSteps: [Step] = []
        var recoverSteps: [Step] = []
        var expectingWork = true
        while index < steps.count, steps[index].kind == .work || steps[index].kind == .recover {
            let step = steps[index]
            if expectingWork {
                guard step.kind == .work else { return false }
                workSteps.append(step)
            } else {
                // Recover is optional after the LAST work only.
                if step.kind == .work {
                    workSteps.append(step)
                    expectingWork = false
                    index += 1
                    continue
                }
                recoverSteps.append(step)
            }
            expectingWork.toggle()
            index += 1
        }
        if index < steps.count, steps[index].kind == .cooldown { index += 1 }
        guard index == steps.count, !workSteps.isEmpty else { return workSteps.isEmpty && recoverSteps.isEmpty && index == steps.count }
        // Uniformity: every work step alike, every recover step alike.
        let workUniform = workSteps.allSatisfy { $0.seconds == workSteps[0].seconds && $0.hrZone == workSteps[0].hrZone }
        let recoverUniform = recoverSteps.allSatisfy { $0.seconds == recoverSteps[0].seconds && $0.hrZone == recoverSteps[0].hrZone }
        // The builder emits exactly one fewer recover than work (none trailing).
        let countsMatch = recoverSteps.isEmpty || recoverSteps.count == workSteps.count - 1
        return workUniform && recoverUniform && countsMatch
    }

    /// "6 × 1min / 1min 30s · 32min" — the compact shape used on goal rows
    /// and preset lists. `distance` renders meters for distance steps and
    /// session goals; pass a user-unit formatter at display sites, or take
    /// the metric default ("400 m", "5 km").
    public func structureSummary(distance: (Double) -> String = Self.metricDistance) -> String {
        let works = steps.filter { $0.kind == .work }
        guard let work = works.first else {
            var parts: [String] = []
            if let goal, goal.isMeaningful { parts.append(goalSummary(distance: distance)) }
            if let zone = hrZoneTarget { parts.append("Zone \(zone) lock") }
            if parts.isEmpty { return "Open" }
            return parts.joined(separator: " · ")
        }
        let recover = steps.first { $0.kind == .recover }
        var text = "\(works.count) × \(Self.stepLength(work, distance: distance))"
        if let recover { text += " / \(Self.stepLength(recover, distance: distance))" }
        if totalSeconds > 0, !hasDistanceSteps {
            text += " · \(Self.shortDuration(totalSeconds)) total"
        } else if totalDistanceMeters > 0 {
            text += " · \(distance(totalDistanceMeters)) of reps"
        }
        return text
    }

    /// Back-compat convenience for existing call sites.
    public var structureSummary: String { structureSummary() }

    private func goalSummary(distance: (Double) -> String) -> String {
        guard let goal else { return "Open" }
        switch goal.kind {
        case .distance: return "\(distance(goal.value)) goal"
        case .duration: return "\(Self.shortDuration(Int(goal.value))) goal"
        case .calories: return "\(Int(goal.value)) kcal goal"
        case .elevation: return "\(distance(goal.value)) climb goal"
        }
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

    private static func stepLength(_ step: Step, distance: (Double) -> String) -> String {
        if step.isDistanceBased, let meters = step.distanceMeters {
            return distance(meters)
        }
        return shortDuration(step.seconds)
    }

    private static func shortDuration(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        if m > 0 && s > 0 { return "\(m)min \(s)s" }
        if m > 0 { return "\(m)min" }
        return "\(s)s"
    }

    /// Unit-pref-free distance ("400 m", "5 km") for core-side summaries.
    public static func metricDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            let km = meters / 1000
            let rounded = (km * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int(rounded)) km" : "\(rounded) km"
        }
        return "\(Int(meters.rounded())) m"
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
