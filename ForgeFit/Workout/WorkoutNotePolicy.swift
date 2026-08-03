import ForgeData
import Foundation

/// Keeps old factory-generated labels out of the user-authored workout-note
/// surface while preserving identical text entered by a user or an importer.
enum WorkoutNotePolicy {
    static func shouldPresentEditor(for workout: WorkoutModel) -> Bool {
        workout.notes != nil && !isLegacyGeneratedNote(in: workout)
    }

    static func userText(in workout: WorkoutModel) -> String? {
        guard !isLegacyGeneratedNote(in: workout),
              let text = workout.notes?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func isLegacyGeneratedNote(in workout: WorkoutModel) -> Bool {
        switch (workout.sourceDevice, workout.notes) {
        case let (source?, "Cardio workout") where source.hasPrefix("iphone-cardio-"):
            true
        case ("iphone-yoga", "Yoga session"):
            true
        default:
            false
        }
    }
}
