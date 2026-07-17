import Foundation

/// The routines CSV: one row per routine target set with the training-cycle
/// hierarchy flattened into leading columns. Folder nesting is one level —
/// a routine in a child folder belongs to that mesocycle inside its parent
/// macrocycle; a routine in a top-level folder belongs to a macrocycle with
/// no mesocycle; ungrouped routines leave both empty. Routines with no sets
/// still get one row so their name and notes survive the export.
public enum RoutineCSVExport {
    public static let header: [String] = [
        "macrocycle", "mesocycle", "routine", "routine_position", "routine_notes",
        "exercise", "exercise_position", "superset_group", "progression_rule", "exercise_notes",
        "set_position", "set_type", "target_reps_low", "target_reps_high",
        "target_weight_kg", "target_rpe", "target_rir", "target_duration_seconds",
        "planned_mini_sets", "planned_mini_reps",
    ]

    public static func csv(library: ExportRoutineLibrary) -> String {
        let foldersByID = Dictionary(
            library.folders.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var rows: [[String]] = []
        for routine in library.routines {
            let (macro, meso) = cycleNames(folderID: routine.folderID, foldersByID: foldersByID)
            let routineColumns = [
                macro,
                meso,
                routine.name,
                CSVWriter.number(routine.position),
                routine.notes ?? "",
            ]
            let setRows = routine.exercises.flatMap { exercise in
                exercise.sets.map { set in
                    routineColumns + [
                        exercise.name,
                        CSVWriter.number(exercise.position),
                        CSVWriter.number(exercise.supersetGroup),
                        exercise.progressionRuleJSON ?? "",
                        exercise.notes ?? "",
                        CSVWriter.number(set.position),
                        set.setType,
                        CSVWriter.number(set.targetRepsLow),
                        CSVWriter.number(set.targetRepsHigh),
                        CSVWriter.number(set.targetWeightKg),
                        CSVWriter.number(set.targetRPE),
                        CSVWriter.number(set.targetRIR),
                        CSVWriter.number(set.targetDurationSeconds),
                        CSVWriter.number(set.plannedMiniSetCount),
                        set.plannedMiniReps.map { $0.map(String.init).joined(separator: "|") } ?? "",
                    ]
                }
            }
            if setRows.isEmpty {
                rows.append(routineColumns + Array(repeating: "", count: header.count - routineColumns.count))
            } else {
                rows.append(contentsOf: setRows)
            }
        }
        return CSVWriter.document(header: header, rows: rows)
    }

    /// (macrocycle, mesocycle) for a routine's owning folder.
    static func cycleNames(
        folderID: UUID?,
        foldersByID: [UUID: ExportRoutineFolder]
    ) -> (macro: String, meso: String) {
        guard let folderID, let folder = foldersByID[folderID] else { return ("", "") }
        if let parentID = folder.parentID, let parent = foldersByID[parentID] {
            return (parent.name, folder.name)
        }
        return (folder.name, "")
    }
}
