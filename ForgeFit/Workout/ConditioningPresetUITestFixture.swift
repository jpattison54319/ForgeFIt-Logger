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
        let conditioningStartedAt = startedAt.addingTimeInterval(376)
        let conditioningEndedAt = conditioningStartedAt.addingTimeInterval(1_184)
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: conditioningStartedAt,
            liveStartedAt: conditioningStartedAt,
            endedAt: conditioningEndedAt,
            sourceDevice: "watch",
            durationSeconds: 1_184,
            activeEnergyKcal: 250,
            avgHR: 166,
            maxHR: 178
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "100s Chipper",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1_680),
            sourceDevice: "watch",
            avgHR: 145,
            maxHR: 178,
            activeEnergyKcal: 299,
            cardioSessions: [session],
            blocks: [block]
        )
        context.insert(workout)
        try context.save()

        // Keep the compiler and fixture honest: the saved identity is the one
        // launch reconciliation must stamp into the legacy workout.
        assert(saved.name == probeTitle)
    }

    /// Models the short window after a Watch workout is durable but its full
    /// HealthKit series and conditioning result have not reached this view yet.
    static func seedFinalizing(in context: ModelContext) throws {
        let probeTitle = "AX400"
        var probe = FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.title == probeTitle }
        )
        probe.fetchLimit = 1
        guard try context.fetch(probe).isEmpty else { return }

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        guard var section = ConditioningPresetSelection.builtIn(.hundredsChipper)
            .resolvedSection(in: exercises) else { return }
        let saved = try ConditioningPresetStore.save(section, named: probeTitle, in: context)
        guard case .section(let savedSection) = saved.storedConditioningPreset else { return }
        section = savedSection

        let end = Date.now.addingTimeInterval(-20)
        let start = end.addingTimeInterval(-28 * 60)
        let progress = ConditioningProgress(
            round: 11,
            startedAt: start,
            sectionStartedAt: start,
            completedAt: end.addingTimeInterval(-120),
            status: .completed
        )
        let block = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            progressJSON: progress.encodedJSON(),
            resultJSON: nil
        )
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            workoutBlockID: block.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: start,
            liveStartedAt: start,
            endedAt: end.addingTimeInterval(-120),
            sourceDevice: "watch",
            durationSeconds: 26 * 60,
            activeEnergyKcal: 299,
            avgHR: 120,
            maxHR: 171
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: probeTitle,
            startedAt: start,
            endedAt: end,
            sourceDevice: "watch",
            avgHR: 120,
            maxHR: 171,
            activeEnergyKcal: 299,
            cardioSessions: [session],
            blocks: [block]
        )
        context.insert(workout)
        try context.save()
    }
}
#endif
