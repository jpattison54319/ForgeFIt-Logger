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

        public init(id: UUID = UUID(), kind: Kind, seconds: Int, label: String) {
            self.id = id
            self.kind = kind
            self.seconds = seconds
            self.label = label
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) {
        self.steps = steps
    }

    public var totalSeconds: Int {
        steps.reduce(0) { $0 + $1.seconds }
    }

    /// Builder used by the plan editor: expands a repeat structure into the
    /// flat step list that gets persisted and executed.
    public static func build(
        warmupSeconds: Int,
        repeats: Int,
        workSeconds: Int,
        recoverSeconds: Int,
        cooldownSeconds: Int
    ) -> IntervalPlan {
        var steps: [Step] = []
        if warmupSeconds > 0 {
            steps.append(Step(kind: .warmup, seconds: warmupSeconds, label: "Warm-up"))
        }
        if repeats > 0, workSeconds > 0 {
            for round in 1...repeats {
                steps.append(Step(kind: .work, seconds: workSeconds, label: "Work \(round)/\(repeats)"))
                // No trailing recover after the last work rep — cooldown covers it.
                if recoverSeconds > 0, round < repeats {
                    steps.append(Step(kind: .recover, seconds: recoverSeconds, label: "Recover \(round)/\(repeats - 1)"))
                }
            }
        }
        if cooldownSeconds > 0 {
            steps.append(Step(kind: .cooldown, seconds: cooldownSeconds, label: "Cool-down"))
        }
        return IntervalPlan(steps: steps)
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
