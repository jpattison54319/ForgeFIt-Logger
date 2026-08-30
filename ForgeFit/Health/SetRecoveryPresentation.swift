import Foundation

/// Turns recovery units into display sections, so the detail view and the
/// share card render the same grouping from one derivation instead of each
/// re-walking the exercise list.
///
/// A unit can span two exercises (a superset round), so rows can't hang off a
/// single exercise the way the set log does. Sections are therefore built from
/// the units themselves: consecutive units covering the same exercises share a
/// heading, which keeps a superset labelled once on its container rather than
/// badging every leg.
enum SetRecoveryPresentation {
    /// What a view knows about a set that the analyzer doesn't: which row it
    /// belongs to and what it's called in the log.
    struct SetRef: Equatable {
        let exerciseRowID: UUID
        let exerciseName: String
        /// The exercise's authored position in the workout. Headings are built
        /// in this order, never in completion order: a lifter who opens one
        /// round with the second exercise would otherwise flip the heading and
        /// split a single superset into two sections.
        let exerciseOrder: Int
        /// The set's own numbered badge in the log ("2", "3W").
        let label: String

        init(exerciseRowID: UUID, exerciseName: String, exerciseOrder: Int, label: String) {
            self.exerciseRowID = exerciseRowID
            self.exerciseName = exerciseName
            self.exerciseOrder = exerciseOrder
            self.label = label
        }
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let label: String
        let point: SetRecoveryPoint
    }

    struct Section: Identifiable, Equatable {
        let id: UUID
        let title: String
        let rows: [Row]
    }

    static func sections(points: [SetRecoveryPoint], refs: [UUID: SetRef]) -> [Section] {
        var sections: [Section] = []
        var currentTitle: String?
        var currentRows: [Row] = []

        func flush() {
            guard let title = currentTitle, let first = currentRows.first else { return }
            sections.append(Section(id: first.id, title: title, rows: currentRows))
            currentRows = []
            currentTitle = nil
        }

        for point in points {
            let resolved = point.setIDs.compactMap { refs[$0] }
            guard resolved.count == point.setIDs.count, let base = resolved.first else { continue }

            var members: [(order: Int, name: String)] = []
            for ref in resolved where !members.contains(where: { $0.name == ref.exerciseName }) {
                members.append((ref.exerciseOrder, ref.exerciseName))
            }
            let title = members
                .sorted { $0.order == $1.order ? $0.name < $1.name : $0.order < $1.order }
                .map(\.name)
                .joined(separator: " + ")
            if title != currentTitle { flush(); currentTitle = title }

            currentRows.append(Row(id: point.id, label: label(for: point, resolved: resolved, base: base, roundOrdinal: currentRows.count + 1), point: point))
        }
        flush()
        return sections
    }

    /// Single sets keep their log badge. A drop chain keeps the base set's
    /// badge with a chevron, because that is how the set log already draws it.
    /// A superset round can't borrow either member's numbering without implying
    /// the rest belonged to that leg, so it is numbered as a round.
    private static func label(
        for point: SetRecoveryPoint,
        resolved: [SetRef],
        base: SetRef,
        roundOrdinal: Int
    ) -> String {
        guard point.setIDs.count > 1 else { return base.label }
        let spansOneExercise = resolved.allSatisfy { $0.exerciseRowID == base.exerciseRowID }
        return spansOneExercise ? "\(base.label)▾" : "R\(roundOrdinal)"
    }
}
