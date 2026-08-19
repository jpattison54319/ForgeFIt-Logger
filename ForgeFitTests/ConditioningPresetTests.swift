import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct ConditioningPresetTests {
    @Test func cindyHasItsCanonicalExercisesAndPrescription() {
        let preset = ConditioningPreset.cindy

        #expect(preset.movements.map(\.catalogName) == ["Pullups", "Pushups", "Bodyweight Squat"])
        #expect(preset.movements.map(\.targetValue) == [5, 10, 15])

        let plan = preset.makePlan(exerciseIDs: [UUID(), UUID(), UUID()])
        let section = plan.sections.first
        #expect(section?.format == .amrap)
        #expect(section?.durationSeconds == 1_200)
        #expect(section?.movements.map(\.targetValue) == [5, 10, 15])
    }

    @Test func everyPresetBuildsAPlanWithEveryDeclaredExercise() {
        for preset in ConditioningPreset.allCases {
            let plan = preset.makePlan(exerciseIDs: preset.movements.map { _ in UUID() })
            #expect(plan.sections.count == 1)
            #expect(plan.sections.first?.movements.count == preset.movements.count)
            #expect(plan.sections.first?.movements.isEmpty == false)
        }
    }

    @Test func includedPresetDetailResolvesTheLiveCatalogInPresetOrder() throws {
        let catalog = ConditioningPreset.hundredsChipper.movements.reversed().map {
            ExerciseLibraryModel(name: $0.catalogName, defaultWeightMode: $0.weightMode)
        }

        let section = try #require(
            ConditioningPresetSelection.builtIn(.hundredsChipper)
                .resolvedSection(in: catalog)
        )
        let catalogByName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.id) })

        #expect(section.name == "100s Chipper")
        #expect(section.presetReferenceID == "built-in-hundredsChipper")
        #expect(section.movements.map(\.exerciseID) == ConditioningPreset.hundredsChipper.movements.compactMap {
            catalogByName[$0.catalogName]
        })
    }

    @Test func hundredsChipperDefaultsToTenRoundsOfTen() throws {
        let preset = ConditioningPreset.hundredsChipper
        let section = try #require(
            preset.makePlan(exerciseIDs: preset.movements.map { _ in UUID() }).sections.first
        )

        #expect(section.format == .forTime)
        #expect(preset.menuTitle == "100s Chipper · 10 rounds × 10")
        #expect(section.rounds == 10)
        #expect(section.movements.map(\.targetValue) == [10, 10, 10, 10])
        #expect(section.movements.map { section.target(for: $0, round: 10) } == [10, 10, 10, 10])
    }

    @Test func twentyOneFifteenNineIsAnExplicitDescendingLadderForTime() throws {
        let preset = ConditioningPreset.twentyOneFifteenNine
        let section = try #require(
            preset.makePlan(exerciseIDs: preset.movements.map { _ in UUID() }).sections.first
        )
        let movement = try #require(section.movements.first)

        #expect(section.format == .ladder)
        #expect(section.scoreKind == .elapsedTime)
        #expect(section.repScheme == [21, 15, 9])
        #expect(section.prescribedRounds == 3)
        #expect((1...3).map { section.target(for: movement, round: $0) } == [21, 15, 9])
    }

    @Test func applyingPresetChangesOnlyItsSectionAndPreservesExistingRowIdentity() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }

        let oldExercise = ExerciseLibraryModel(name: "Bench Press")
        let oldRow = RoutineExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: oldExercise.id,
            sets: [RoutineSetModel(userID: ForgeFitDemo.userID, targetRepsLow: 8)]
        )
        let strengthSection = ConditioningSection(
            name: "Strength",
            format: .forTime,
            rounds: 3,
            movements: [ConditioningMovement(exerciseID: oldExercise.id, targetValue: 8)]
        )
        let conditioningSection = ConditioningSection(name: "Finisher", format: .amrap, durationSeconds: 600)
        var plan = ConditioningPlan(sections: [strengthSection, conditioningSection])
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Mixed Session",
            conditioningPlanJSON: plan.encodedJSON(),
            exercises: [oldRow]
        )
        let catalog = ConditioningPreset.cindy.movements.map {
            ExerciseLibraryModel(name: $0.catalogName, defaultWeightMode: $0.weightMode)
        }
        context.insert(oldExercise)
        catalog.forEach(context.insert)
        context.insert(routine)

        try ConditioningPlanCoordinator.apply(
            .cindy,
            to: conditioningSection.id,
            in: &plan,
            to: routine,
            catalog: catalog,
            in: context
        )
        try context.save()

        let sortedRows = routine.exercises.sorted { $0.position < $1.position }
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.name) })
        #expect(routine.name == "Mixed Session")
        #expect(plan.sections.first == strengthSection)
        #expect(plan.sections[1].name == "Cindy")
        #expect(plan.sections[1].movements.map(\.targetValue) == [5, 10, 15])
        #expect(sortedRows.first?.id == oldRow.id)
        #expect(sortedRows.dropFirst().compactMap { catalogByID[$0.exerciseID] } == ["Pullups", "Pushups", "Bodyweight Squat"])
        #expect(ConditioningPlan.decode(from: routine.conditioningPlanJSON) == plan)
    }

    @Test func switchingPresetsReusesSharedMovementRows() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let names = Set(
            ConditioningPreset.cindy.movements.map(\.catalogName)
                + ConditioningPreset.hundredsChipper.movements.map(\.catalogName)
        )
        let catalog = names.map { ExerciseLibraryModel(name: $0, defaultWeightMode: .bodyweight) }
        catalog.forEach(context.insert)
        let section = ConditioningSection(name: "Section 1", format: .amrap, durationSeconds: 600)
        var plan = ConditioningPlan(sections: [section])
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Conditioning",
            conditioningPlanJSON: plan.encodedJSON()
        )
        context.insert(routine)

        try ConditioningPlanCoordinator.apply(
            .cindy,
            to: section.id,
            in: &plan,
            to: routine,
            catalog: catalog,
            in: context
        )
        let cindyRows = Dictionary(uniqueKeysWithValues: routine.exercises.map { ($0.exerciseID, $0.id) })

        try ConditioningPlanCoordinator.apply(
            .hundredsChipper,
            to: section.id,
            in: &plan,
            to: routine,
            catalog: catalog,
            in: context
        )
        let rowByExercise = Dictionary(uniqueKeysWithValues: routine.exercises.map { ($0.exerciseID, $0.id) })
        let exerciseByName = Dictionary(uniqueKeysWithValues: catalog.map { ($0.name, $0.id) })
        let pushupsID = try #require(exerciseByName["Pushups"])
        let squatID = try #require(exerciseByName["Bodyweight Squat"])

        #expect(rowByExercise[pushupsID] == cindyRows[pushupsID])
        #expect(rowByExercise[squatID] == cindyRows[squatID])
        #expect(routine.exercises.count == 4)
    }

    @Test func customPresetRoundTripsItsNameAndFrozenSectionThroughTheSyncedStore() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let exerciseID = UUID()
        let section = ConditioningSection(
            name: "Cindy",
            format: .amrap,
            durationSeconds: 1_200,
            movements: [ConditioningMovement(exerciseID: exerciseID, targetValue: 10)]
        )

        let stored = try ConditioningPresetStore.save(
            section,
            named: "  Garage Cindy  ",
            in: context
        )

        #expect(stored.name == "Garage Cindy")
        #expect(stored.storedIntervalPlan == nil)
        let decoded = try #require(stored.storedConditioningPreset)
        guard case .section(let storedSection) = decoded else {
            Issue.record("Expected a saved conditioning section payload.")
            return
        }
        #expect(storedSection.name == "Garage Cindy")
        #expect(storedSection.presetReferenceID == "saved-\(stored.id.uuidString)")
        #expect(storedSection.format == .amrap)
        #expect(storedSection.movements.map(\.exerciseID) == [exerciseID])
    }

    @Test func updatingCustomPresetPersistsItsNewNameOnTheExistingRecord() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let section = ConditioningSection(
            name: "100s Chipper",
            format: .forTime,
            rounds: 10,
            movements: [ConditioningMovement(exerciseID: UUID(), targetValue: 10)]
        )
        let record = try ConditioningPresetStore.save(section, named: section.name, in: context)
        let originalID = record.id

        try ConditioningPresetStore.update(record, with: section, named: "  AX400  ", in: context)

        let fetched = try #require(context.fetch(FetchDescriptor<IntervalPresetModel>()).first)
        #expect(fetched.id == originalID)
        #expect(fetched.name == "AX400")
        guard case .section(let storedSection) = fetched.storedConditioningPreset else {
            Issue.record("Expected the updated conditioning preset payload.")
            return
        }
        #expect(storedSection.name == "AX400")
        #expect(storedSection.presetReferenceID == "saved-\(originalID.uuidString)")
    }

    @Test func legacyPresetOrderStillReconcilesToRenamedSavedPreset() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let catalog = ConditioningPreset.hundredsChipper.movements.map {
            ExerciseLibraryModel(name: $0.catalogName, defaultWeightMode: $0.weightMode)
        }
        catalog.forEach(context.insert)
        let current = try #require(
            ConditioningPresetSelection.builtIn(.hundredsChipper).resolvedSection(in: catalog)
        )
        var legacy = current
        legacy.presetReferenceID = nil
        legacy.movements = [
            current.movements[1],
            current.movements[2],
            current.movements[0],
            current.movements[3]
        ]
        #expect(ConditioningPrescriptionSignature.key(for: legacy) != ConditioningPrescriptionSignature.key(for: current))
        #expect(ConditioningPresetLineageSignature.key(for: legacy) == ConditioningPresetLineageSignature.key(for: current))

        let saved = try ConditioningPresetStore.save(current, named: "AX400", in: context)
        var records = try context.fetch(FetchDescriptor<IntervalPresetModel>())
        try ConditioningPresetStore.hide(.hundredsChipper, records: records, in: context)
        records = try context.fetch(FetchDescriptor<IntervalPresetModel>())

        let result = ConditioningSectionResult(
            id: legacy.id,
            format: legacy.format,
            scoreKind: legacy.scoreKind,
            elapsedSeconds: 1_184,
            fullRounds: 10,
            completed: true
        )
        let block = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planSnapshotJSON: ConditioningPlan(sections: [legacy]).encodedJSON(),
            resultJSON: ConditioningResult(sectionResults: [result]).encodedJSON()
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "100s Chipper",
            startedAt: Date(timeIntervalSince1970: 1_786_633_200),
            endedAt: Date(timeIntervalSince1970: 1_786_634_384),
            blocks: [block]
        )
        context.insert(workout)
        try context.save()

        let updated = try ConditioningPresetHistoryReconciler.reconcile(
            records: records,
            workouts: [workout],
            exercises: catalog,
            context: context
        )

        let migrated = try #require(
            ConditioningPlan.decode(from: block.planSnapshotJSON)?.sections.first
        )
        #expect(updated == 1)
        #expect(migrated.name == "AX400")
        #expect(migrated.presetReferenceID == "saved-\(saved.id.uuidString)")
        #expect(workout.title == "AX400")
        let selection = try #require(ConditioningPresetResolver.selection(
            for: migrated,
            records: records,
            exercises: catalog
        ))
        #expect(selection.id == "saved-\(saved.id.uuidString)")
        #expect(selection.title == "AX400")
        #expect(ConditioningPresetStats.entries(for: current, in: [workout]).count == 1)
    }

    @Test func renamingPresetUpdatesMatchingLegacyAndBlockHistoryOnly() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let exerciseID = UUID()
        let source = ConditioningSection(
            name: "100s Chipper",
            format: .forTime,
            rounds: 10,
            movements: [ConditioningMovement(exerciseID: exerciseID, targetValue: 10)]
        )
        let matchingLegacy = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: source.name,
            endedAt: .now,
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [source]).encodedJSON()
        )
        let matchingBlock = WorkoutBlockModel(
            userID: ForgeFitDemo.userID,
            kind: .conditioning,
            planSnapshotJSON: ConditioningPlan(sections: [source]).encodedJSON()
        )
        let matchingBlockWorkout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: source.name,
            endedAt: .now,
            blocks: [matchingBlock]
        )
        var differentPrescription = source
        differentPrescription.rounds = 8
        let unrelated = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: source.name,
            endedAt: .now,
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [differentPrescription]).encodedJSON()
        )
        context.insert(matchingLegacy)
        context.insert(matchingBlockWorkout)
        context.insert(unrelated)
        try context.save()

        try ConditioningPresetHistoryRenamer.renameMatchingHistory(
            from: source,
            to: "AX400",
            presetReferenceID: "saved-\(UUID().uuidString)",
            in: [matchingLegacy, matchingBlockWorkout, unrelated],
            context: context
        )

        let legacyPlan = try #require(ConditioningPlan.decode(from: matchingLegacy.conditioningPlanSnapshotJSON))
        let blockPlan = try #require(ConditioningPlan.decode(from: matchingBlock.planSnapshotJSON))
        let unrelatedPlan = try #require(ConditioningPlan.decode(from: unrelated.conditioningPlanSnapshotJSON))
        #expect(legacyPlan.sections.first?.name == "AX400")
        #expect(blockPlan.sections.first?.name == "AX400")
        #expect(matchingLegacy.title == "AX400")
        #expect(matchingBlockWorkout.title == "AX400")
        #expect(unrelatedPlan.sections.first?.name == "100s Chipper")
        #expect(unrelated.title == "100s Chipper")
    }

    @Test func applyingCustomPresetRenamesOnlyTheTargetSectionAndRefreshesMovementIdentity() throws {
        let exercise = ExerciseLibraryModel(name: "Pullups", defaultWeightMode: .bodyweight)
        let untouched = ConditioningSection(name: "Warmup", format: .forTime, rounds: 2)
        let target = ConditioningSection(name: "Finisher", format: .amrap, durationSeconds: 600)
        let savedMovement = ConditioningMovement(
            exerciseID: exercise.id,
            targetValue: 5,
            weightMode: .bodyweight
        )
        let savedSection = ConditioningSection(
            name: "Renamed Cindy",
            format: .amrap,
            durationSeconds: 1_200,
            movements: [savedMovement]
        )
        var plan = ConditioningPlan(sections: [untouched, target])

        try ConditioningPlanCoordinator.apply(
            .saved(id: UUID(), name: "Renamed Cindy", section: savedSection),
            to: target.id,
            in: &plan,
            catalog: [exercise]
        )

        #expect(plan.sections[0] == untouched)
        #expect(plan.sections[1].id == target.id)
        #expect(plan.sections[1].name == "Renamed Cindy")
        #expect(plan.sections[1].movements.map(\.exerciseID) == [exercise.id])
        #expect(plan.sections[1].movements.first?.id != savedMovement.id)
    }

    @Test func deletingSavedPresetRemovesItFromTheActiveCatalog() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }
        let section = ConditioningSection(
            name: "Garage Cindy",
            format: .amrap,
            durationSeconds: 1_200,
            movements: [ConditioningMovement(exerciseID: UUID(), targetValue: 5)]
        )
        let record = try ConditioningPresetStore.save(section, named: section.name, in: context)

        try ConditioningPresetStore.delete(record, in: context)

        let records = try context.fetch(FetchDescriptor<IntervalPresetModel>())
        #expect(record.deletedAt != nil)
        #expect(ConditioningPresetStore.savedPresets(from: records).isEmpty)
    }

    @Test func deletingAndRestoringAnIncludedPresetChangesTheVisibleCatalog() throws {
        let (container, context) = try TestStore.make()
        defer { withExtendedLifetime(container) {} }

        try ConditioningPresetStore.hide(.cindy, records: [], in: context)
        let activeDescriptor = FetchDescriptor<IntervalPresetModel>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        let recordsAfterDelete = try context.fetch(activeDescriptor)
        #expect(!ConditioningPresetStore.visibleBuiltIns(from: recordsAfterDelete).contains(.cindy))

        try ConditioningPresetStore.restoreIncludedPresets(records: recordsAfterDelete, in: context)
        let recordsAfterRestore = try context.fetch(activeDescriptor)
        #expect(ConditioningPresetStore.visibleBuiltIns(from: recordsAfterRestore).contains(.cindy))
    }
}
