#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum ConditioningPresetUITestFixture {
    static func seed(in context: ModelContext) throws {
        let probeTitle = "AX400"
        var probe = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == probeTitle }
        )
        probe.fetchLimit = 1
        guard try context.fetch(probe).isEmpty else { return }

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        guard let current = ConditioningPresetSelection.builtIn(.hundredsChipper)
            .resolvedSection(in: exercises),
              current.movements.count == 4 else { return }

        let saved = try ConditioningPresetStore.save(current, named: probeTitle, in: context)
        let records = try context.fetch(FetchDescriptor<IntervalPresetModel>())
        try ConditioningPresetStore.hide(.hundredsChipper, records: records, in: context)

        var legacy = current
        legacy.name = "100s Chipper"
        legacy.presetReferenceID = nil
        legacy.movements = [
            current.movements[1],
            current.movements[2],
            current.movements[0],
            current.movements[3]
        ]
        let result = ConditioningSectionResult(
            id: legacy.id,
            format: legacy.format,
            scoreKind: legacy.scoreKind,
            elapsedSeconds: 1_184,
            fullRounds: 10,
            totalReps: 400,
            completed: true
        )
        let block = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planSnapshotJSON: ConditioningPlan(sections: [legacy]).encodedJSON(),
            resultJSON: ConditioningResult(sectionResults: [result]).encodedJSON()
        )
        let startedAt = Date.now.addingTimeInterval(-86_400)
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "100s Chipper",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_184),
            blocks: [block]
        )
        context.insert(workout)
        try context.save()

        // Keep the compiler and fixture honest: the saved identity is the one
        // launch reconciliation must stamp into the legacy workout.
        assert(saved.name == probeTitle)
    }
}
#endif
