import ForgeCore
import ForgeData
import Foundation

/// What is still unticked when the lifter taps Finish.
///
/// Finishing is not blocked by this — plenty of sessions end early on purpose,
/// and a session that stops short is a legitimate result. The one thing worth
/// interrupting for is the *accident*: a set skipped by mistake, or a whole
/// exercise never started because it scrolled off the bottom. So this states
/// what would be dropped and lets the lifter decide.
///
/// Warm-up sets are deliberately excluded. They're routinely left unticked by
/// people who did them, and warning about them would train the habit of
/// dismissing this prompt without reading it.
struct IncompleteWorkSummary: Equatable {
    /// Unticked working sets belonging to exercises that were at least started.
    let unfinishedSetCount: Int
    /// Names of exercises where nothing at all was completed.
    let untouchedExerciseNames: [String]

    var isEmpty: Bool { unfinishedSetCount == 0 && untouchedExerciseNames.isEmpty }

    /// One sentence naming what is unticked, specific enough to recognise a
    /// mistake without having to reopen the log.
    var message: String {
        var clauses: [String] = []
        if unfinishedSetCount > 0 {
            clauses.append("\(unfinishedSetCount) set\(unfinishedSetCount == 1 ? "" : "s")")
        }
        if !untouchedExerciseNames.isEmpty {
            clauses.append(listPhrase(untouchedExerciseNames))
        }

        let subject: String
        switch clauses.count {
        case 0: return ""
        case 1: subject = clauses[0]
        default: subject = "\(clauses[0]) and \(clauses[1])"
        }

        let plural = unfinishedSetCount > 1
            || untouchedExerciseNames.count > 1
            || clauses.count > 1
        return "\(subject) \(plural ? "aren't" : "isn't") marked complete. "
            + "Unticked work isn't saved to this workout."
    }

    /// "Lat Pulldown" · "Lat Pulldown and Face Pull" · "Lat Pulldown, Face Pull
    /// and 2 more" — the tail is capped so the alert stays one readable line.
    private func listPhrase(_ names: [String]) -> String {
        switch names.count {
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }

    /// Inspects a live workout. `exerciseNames` resolves library ids to display
    /// names; an unresolved id falls back to a neutral label rather than
    /// dropping the exercise from the warning.
    static func make(
        for workout: WorkoutModel,
        exerciseNames: [UUID: String]
    ) -> IncompleteWorkSummary {
        var unfinishedSetCount = 0
        var untouchedExerciseNames: [String] = []

        let rows = workout.exercises
            .filter { $0.generatedByWorkoutBlockID == nil }
            .sorted { $0.position < $1.position }

        for row in rows {
            let working = row.sets.filter { $0.setType.countsAsWorkingVolume }
            // Session-based rows (cardio, yoga) carry no sets — their
            // completion lives in a CardioSessionModel and is already covered
            // by the conditioning/target guards.
            guard !working.isEmpty else { continue }

            let completed = working.filter { $0.completedAt != nil }
            if completed.isEmpty {
                untouchedExerciseNames.append(exerciseNames[row.exerciseID] ?? "an exercise")
            } else {
                unfinishedSetCount += working.count - completed.count
            }
        }

        return IncompleteWorkSummary(
            unfinishedSetCount: unfinishedSetCount,
            untouchedExerciseNames: untouchedExerciseNames
        )
    }
}
