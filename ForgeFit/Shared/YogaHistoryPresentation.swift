import ForgeCore
import ForgeData
import Foundation

/// A display-only reading of yoga work. The runner stores left and right holds
/// separately so it can time and credit them accurately; history and sharing
/// fold an adjacent pair back into the single pose the user practiced.
enum YogaHistoryPresentation {
    struct Pose: Identifiable, Equatable {
        let id: String
        let name: String
        let durationSeconds: Int
        let sideDetail: String?
    }

    static func poses(session: CardioSessionModel?, plan: YogaFlowPlan?) -> [Pose] {
        let splits = session?.splits
            .filter { $0.label?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .sorted { $0.index < $1.index } ?? []
        if !splits.isEmpty {
            var rows: [Pose] = []
            var index = 0
            while index < splits.count {
                let split = splits[index]
                let first = parsed(split.label ?? "Pose")
                if index + 1 < splits.count {
                    let next = splits[index + 1]
                    let second = parsed(next.label ?? "Pose")
                    if first.name == second.name,
                       Set([first.side, second.side].compactMap { $0 }) == Set(["Left", "Right"]) {
                        rows.append(Pose(
                            id: "\(split.id)-\(next.id)",
                            name: first.name,
                            durationSeconds: split.durationSeconds + next.durationSeconds,
                            sideDetail: "Both sides"
                        ))
                        index += 2
                        continue
                    }
                }
                rows.append(Pose(
                    id: split.id.uuidString,
                    name: first.name,
                    durationSeconds: split.durationSeconds,
                    sideDetail: first.side
                ))
                index += 1
            }
            return rows
        }

        return plan?.steps.map { step in
            Pose(
                id: step.id.uuidString,
                name: step.name,
                durationSeconds: step.holdSeconds * (step.side == .bothSides ? 2 : 1),
                sideDetail: step.side == .bothSides ? "Both sides" : step.side?.rawValue.capitalized
            )
        } ?? []
    }

    static func poseCount(session: CardioSessionModel?, plan: YogaFlowPlan?) -> Int {
        if let count = session?.logicalYogaPosesCompleted { return count }
        return plan?.steps.count ?? 0
    }

    static func title(
        session: CardioSessionModel,
        plan: YogaFlowPlan?,
        exercise: ExerciseLibraryModel?
    ) -> String {
        if let plan, plan.steps.count == 1 { return plan.steps[0].name }
        if let exercise, plan?.steps.count ?? 0 <= 1 { return exercise.name }
        return "\(session.resolvedYogaStyle.title) Yoga"
    }

    static func compactSummary(
        session: CardioSessionModel,
        plan: YogaFlowPlan?,
        averageHeartRate: Int? = nil
    ) -> String {
        var parts = [Fmt.durationShort(session.durationSeconds)]
        let count = poseCount(session: session, plan: plan)
        if count > 0 { parts.append("\(count) pose\(count == 1 ? "" : "s")") }
        if let hr = averageHeartRate ?? session.avgHR { parts.append("\(hr) bpm") }
        return parts.joined(separator: " · ")
    }

    private static func parsed(_ label: String) -> (name: String, side: String?) {
        for side in ["Left", "Right"] where label.hasSuffix(" — \(side)") {
            return (String(label.dropLast(side.count + 3)), side)
        }
        return (label, nil)
    }
}
