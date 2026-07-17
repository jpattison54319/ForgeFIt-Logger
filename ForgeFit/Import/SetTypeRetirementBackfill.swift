import Foundation
import ForgeCore
import ForgeData
import SwiftData

/// One-shot migration retiring the rest-pause set type: in practice it was
/// indistinguishable from myo-reps (activation + micro-rested minis), so the
/// picker no longer offers it and existing sets — logged history and routine
/// plans alike — convert to myo-reps. The enum case itself survives so
/// not-yet-migrated CloudKit data from other devices still decodes; this
/// backfill simply runs again for it on the next launch.
@MainActor
enum SetTypeRetirementBackfill {
    private static let restPauseRaw = SetType.restPause.rawValue

    static func run(in context: ModelContext) {
        let sets = (try? context.fetch(FetchDescriptor<SetModel>(
            predicate: #Predicate { $0.setTypeRaw == restPauseRaw }
        ))) ?? []
        let routineSets = (try? context.fetch(FetchDescriptor<RoutineSetModel>(
            predicate: #Predicate { $0.setTypeRaw == restPauseRaw }
        ))) ?? []
        guard !sets.isEmpty || !routineSets.isEmpty else { return }

        for set in sets {
            set.setType = .myoRep
            set.updatedAt = Date()
        }
        for set in routineSets {
            set.setType = .myoRep
        }
        try? context.save()
    }
}
