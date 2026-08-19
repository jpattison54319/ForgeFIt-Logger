import ForgeCore
import ForgeData
import Foundation
import SwiftData

struct ConditioningPresetMovement: Equatable, Sendable {
    let catalogName: String
    let targetValue: Double
    var targetUnit: ConditioningTargetUnit = .reps
    var targetLoad: Double?
    var weightMode: WeightMode
}

enum ConditioningPreset: String, CaseIterable, Identifiable, Sendable {
    case cindy
    case hundredsChipper
    case twentyOneFifteenNine
    case emom
    case tabata
    case ladder
    case maxLoad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cindy: "Cindy"
        case .hundredsChipper: "100s Chipper"
        case .twentyOneFifteenNine: "21–15–9 Ladder"
        case .emom: "10-Minute EMOM"
        case .tabata: "Tabata Squats"
        case .ladder: "Push-Up + Sit-Up Ladder"
        case .maxLoad: "5-Rep Kettlebell Thruster"
        }
    }

    var menuTitle: String {
        switch self {
        case .cindy: "Cindy · 20 min AMRAP"
        case .hundredsChipper: "100s Chipper · 10 rounds × 10"
        case .twentyOneFifteenNine: "21–15–9 · Descending Ladder"
        case .emom: "Kettlebell Thrusters · EMOM"
        case .tabata: "Bodyweight Squats · Tabata"
        case .ladder: "Push-Ups + Sit-Ups · Ladder"
        case .maxLoad: "Kettlebell Thruster · For Load"
        }
    }

    var summary: String {
        switch self {
        case .cindy: "20 min AMRAP"
        case .hundredsChipper: "10 rounds × 10"
        case .twentyOneFifteenNine: "Descending ladder"
        case .emom: "10-minute EMOM"
        case .tabata: "8 × 20 sec work / 10 sec rest"
        case .ladder: "10-round ascending ladder"
        case .maxLoad: "5 attempts for load"
        }
    }

    var movements: [ConditioningPresetMovement] {
        switch self {
        case .cindy:
            [
                .init(catalogName: "Pullups", targetValue: 5, weightMode: .bodyweight),
                .init(catalogName: "Pushups", targetValue: 10, weightMode: .bodyweight),
                .init(catalogName: "Bodyweight Squat", targetValue: 15, weightMode: .bodyweight),
            ]
        case .hundredsChipper:
            [
                .init(catalogName: "Pushups", targetValue: 10, weightMode: .bodyweight),
                .init(catalogName: "Inverted Row", targetValue: 10, weightMode: .bodyweight),
                .init(catalogName: "Sit-Up", targetValue: 10, weightMode: .bodyweight),
                .init(catalogName: "Bodyweight Squat", targetValue: 10, weightMode: .bodyweight),
            ]
        case .twentyOneFifteenNine:
            [
                .init(catalogName: "Kettlebell Thruster", targetValue: 21, weightMode: .external),
                .init(catalogName: "Pullups", targetValue: 21, weightMode: .bodyweight),
            ]
        case .emom:
            [.init(catalogName: "Kettlebell Thruster", targetValue: 8, weightMode: .external)]
        case .tabata:
            [.init(catalogName: "Bodyweight Squat", targetValue: 20, targetUnit: .seconds, weightMode: .bodyweight)]
        case .ladder:
            [
                .init(catalogName: "Pushups", targetValue: 2, weightMode: .bodyweight),
                .init(catalogName: "Sit-Up", targetValue: 2, weightMode: .bodyweight),
            ]
        case .maxLoad:
            [.init(catalogName: "Kettlebell Thruster", targetValue: 5, weightMode: .external)]
        }
    }

    func makeSection(exerciseIDs: [UUID], id: UUID = UUID()) -> ConditioningSection {
        let resolvedMovements = zip(movements, exerciseIDs).map { spec, exerciseID in
            ConditioningMovement(
                exerciseID: exerciseID,
                targetValue: spec.targetValue,
                targetUnit: spec.targetUnit,
                targetLoad: spec.targetLoad,
                weightMode: spec.weightMode
            )
        }

        var section = switch self {
        case .cindy:
            ConditioningSection(id: id, name: title, format: .amrap, durationSeconds: 1_200, movements: resolvedMovements)
        case .hundredsChipper:
            ConditioningSection(id: id, name: title, format: .forTime, ordering: .inOrder, rounds: 10, movements: resolvedMovements)
        case .twentyOneFifteenNine:
            ConditioningSection(
                id: id,
                name: title,
                format: .ladder,
                scoreKind: .elapsedTime,
                repScheme: [21, 15, 9],
                movements: resolvedMovements
            )
        case .emom:
            ConditioningSection(id: id, name: title, format: .emom, rounds: 10, intervalSeconds: 60, movements: resolvedMovements)
        case .tabata:
            ConditioningSection(
                id: id,
                name: title,
                format: .intervals,
                durationSeconds: 240,
                rounds: 8,
                workSeconds: 20,
                restSeconds: 10,
                movements: resolvedMovements
            )
        case .ladder:
            ConditioningSection(id: id, name: title, format: .ladder, rounds: 10, ladderStep: 2, movements: resolvedMovements)
        case .maxLoad:
            ConditioningSection(id: id, name: title, format: .maxLoad, timeCapSeconds: 600, rounds: 5, movements: resolvedMovements)
        }
        section.presetReferenceID = "built-in-\(self.id)"
        return section
    }

    func makePlan(exerciseIDs: [UUID]) -> ConditioningPlan {
        ConditioningPlan(sections: [makeSection(exerciseIDs: exerciseIDs)])
    }
}

@MainActor
enum ConditioningPlanCoordinator {
    enum ApplyError: LocalizedError {
        case missingExercise(String)
        case missingSavedExercise
        case missingSection

        var errorDescription: String? {
            switch self {
            case .missingExercise(let name): "The exercise library is missing \(name)."
            case .missingSavedExercise: "A movement in this saved preset is no longer in your exercise library."
            case .missingSection: "That conditioning section no longer exists."
            }
        }
    }

    static func apply(
        _ preset: ConditioningPreset,
        to sectionID: UUID,
        in plan: inout ConditioningPlan,
        catalog: [ExerciseLibraryModel]
    ) throws {
        guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }) else {
            throw ApplyError.missingSection
        }
        let catalogByName = Dictionary(
            catalog.lazy
                .filter { $0.deletedAt == nil }
                .map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let resolved = try preset.movements.map { movement in
            guard let exercise = catalogByName[movement.catalogName.lowercased()] else {
                throw ApplyError.missingExercise(movement.catalogName)
            }
            return exercise
        }
        plan.sections[sectionIndex] = preset.makeSection(
            exerciseIDs: resolved.map(\.id),
            id: sectionID
        )
    }

    static func apply(
        _ selection: ConditioningPresetSelection,
        to sectionID: UUID,
        in plan: inout ConditioningPlan,
        catalog: [ExerciseLibraryModel]
    ) throws {
        switch selection {
        case .builtIn(let preset):
            try apply(preset, to: sectionID, in: &plan, catalog: catalog)
        case .saved(_, _, let savedSection):
            guard let sectionIndex = plan.sections.firstIndex(where: { $0.id == sectionID }) else {
                throw ApplyError.missingSection
            }
            let availableExerciseIDs = Set(catalog.lazy.filter { $0.deletedAt == nil }.map(\.id))
            guard savedSection.movements.allSatisfy({ availableExerciseIDs.contains($0.exerciseID) }) else {
                throw ApplyError.missingSavedExercise
            }

            var replacement = savedSection
            replacement.id = sectionID
            replacement.presetReferenceID = selection.id
            replacement.movements = savedSection.movements.map { movement in
                var copy = movement
                copy.id = UUID()
                return copy
            }
            plan.sections[sectionIndex] = replacement
        }
    }

    static func apply(
        _ preset: ConditioningPreset,
        to sectionID: UUID,
        in plan: inout ConditioningPlan,
        to routine: RoutineModel,
        catalog: [ExerciseLibraryModel],
        in context: ModelContext
    ) throws {
        try apply(preset, to: sectionID, in: &plan, catalog: catalog)
        reconcileRoutineExercises(with: plan, routine: routine, in: context)
        routine.conditioningPlanJSON = plan.encodedJSON()
        routine.updatedAt = .now
    }

    static func apply(
        _ selection: ConditioningPresetSelection,
        to sectionID: UUID,
        in plan: inout ConditioningPlan,
        to routine: RoutineModel,
        catalog: [ExerciseLibraryModel],
        in context: ModelContext
    ) throws {
        try apply(selection, to: sectionID, in: &plan, catalog: catalog)
        reconcileRoutineExercises(with: plan, routine: routine, in: context)
        routine.conditioningPlanJSON = plan.encodedJSON()
        routine.updatedAt = .now
    }

    /// Keeps the routine relationship as a lightweight union of section
    /// movements. Existing rows retain identity; only actual additions and
    /// removals touch SwiftData, so changing one section does not rebuild the
    /// entire routine or stall the main thread.
    static func reconcileRoutineExercises(
        with plan: ConditioningPlan,
        routine: RoutineModel,
        in context: ModelContext
    ) {
        var seen = Set<UUID>()
        let desiredMovements = plan.sections
            .flatMap(\.movements)
            .filter { seen.insert($0.exerciseID).inserted }
        var available = Dictionary(grouping: routine.exercises, by: \.exerciseID)
        var reconciled: [RoutineExerciseModel] = []

        for (position, movement) in desiredMovements.enumerated() {
            if var rows = available[movement.exerciseID], let row = rows.first {
                rows.removeFirst()
                available[movement.exerciseID] = rows
                row.position = position
                reconciled.append(row)
                continue
            }
            let target = RoutineSetModel(
                userID: routine.userID,
                position: 0,
                targetRepsLow: movement.targetUnit == .reps ? Int(movement.targetValue) : nil,
                targetRepsHigh: movement.targetUnit == .reps ? Int(movement.targetValue) : nil,
                targetWeight: movement.targetLoad,
                targetDurationSeconds: movement.targetUnit == .seconds ? Int(movement.targetValue) : nil,
                targetDistanceMeters: movement.targetUnit == .meters ? movement.targetValue : nil
            )
            let routineExercise = RoutineExerciseModel(
                userID: routine.userID,
                exerciseID: movement.exerciseID,
                position: position,
                sets: [target]
            )
            context.insert(target)
            context.insert(routineExercise)
            reconciled.append(routineExercise)
        }

        available.values.flatMap { $0 }.forEach(context.delete)
        routine.exercises = reconciled
    }
}
