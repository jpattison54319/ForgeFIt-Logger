import ForgeData
import Foundation
import SwiftData

/// The onboarding dismissal cleanup must remove only the app's *seeded* first-
/// run content, never genuine user work-in-progress. The only seeded starter
/// training content is the starter routine ("Full Body A") and its setup note;
/// no starter workout is created by the seeding path, so the set of deletable
/// workouts is defined by provenance rather than a new marker.
enum StarterSlatePolicy {
    /// A workout counts as seeded starter data when it is unfinished AND was
    /// started from the seeded starter routine. `WorkoutModel.routineID` is the
    /// existing provenance stamp `WorkoutFactory.start` writes (the routine's
    /// id); ad-hoc empty starts, cardio/yoga quick starts (`routineID == nil`),
    /// and workouts from any other routine are real user work and survive
    /// onboarding. Completed sessions are history and are never removed.
    static func isSeededStarterWorkout(_ workout: WorkoutModel) -> Bool {
        workout.endedAt == nil && workout.routineID == ForgeFitDemo.starterRoutineID
    }

    /// Decides whether the global workout runtime may be torn down at slate
    /// cleanup. True only when the currently active workout is itself the
    /// seeded starter workout being deleted — a preserved genuine workout
    /// keeps its rest timers, GPS/cardio recording, watch state, HR stream,
    /// and Live Activity.
    static func cancelsLiveRuntimeForDeletion(activeWorkout: WorkoutModel?) -> Bool {
        guard let activeWorkout else { return false }
        return isSeededStarterWorkout(activeWorkout)
    }
}

/// The deletion half of `clearStarterSlate`, extracted so its effects are
/// testable against a store without mounting ContentView. Deletes:
/// 1. unfinished workouts started from the seeded starter routine,
/// 2. the seeded starter routine itself,
/// 3. the seeded starter setup note (`ForgeFitDemo.machinePressNoteID`).
/// Everything else — completed workouts, unfinished workouts that are not
/// starter-derived, and user-authored (pinned) notes, which ride the same
/// demo `userID` as the seeded note — is left untouched.
enum StarterSlateCleanup {
    @MainActor
    static func run(in context: ModelContext) throws {
        let starterRoutineID = ForgeFitDemo.starterRoutineID
        for workout in try context.fetch(FetchDescriptor<WorkoutModel>())
        where StarterSlatePolicy.isSeededStarterWorkout(workout) {
            context.delete(workout)
        }

        let starterRoutines = try context.fetch(
            FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == starterRoutineID })
        )
        for routine in starterRoutines {
            context.delete(routine)
        }

        // The seeded starter setup note, identified by its fixed demo ID.
        // `userID` cannot narrow this: real user-authored (pinned) notes carry
        // the same demo user ID as seeded content.
        let seededNoteID = ForgeFitDemo.machinePressNoteID
        let seededNotes = try context.fetch(
            FetchDescriptor<UserExerciseNoteModel>(predicate: #Predicate { $0.id == seededNoteID })
        )
        for note in seededNotes {
            context.delete(note)
        }

        try context.save()
    }
}