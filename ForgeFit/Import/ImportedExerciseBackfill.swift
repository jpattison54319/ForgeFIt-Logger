import Foundation
import ForgeCore
import ForgeData
import SwiftData

@MainActor
enum ImportedExerciseBackfill {
    static let didRunKey = "importedExerciseClassificationBackfill.v2.didRun"

    static func runIfNeeded(
        in context: ModelContext,
        defaults: UserDefaults = .standard,
        save: @escaping @MainActor @Sendable (ModelContext) throws -> Void = { try $0.save() }
    ) async {
        guard LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              !defaults.bool(forKey: didRunKey) else { return }

        let descriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { exercise in
                exercise.ownerID != nil
                    && exercise.deletedAt == nil
                    && exercise.importBatchID != nil
                    && exercise.userModified == false
            }
        )
        let candidates: [ExerciseLibraryModel]
        do {
            candidates = try context.fetch(descriptor)
        } catch {
            // A transient store read must not permanently suppress this repair.
            return
        }

        guard !candidates.isEmpty else {
            defaults.set(true, forKey: didRunKey)
            return
        }

        let seedCorpus = WorkoutHistoryImportService.seedCorpus()
        let namesByID = Dictionary(candidates.map { ($0.id, $0.importedRawName ?? $0.name) }, uniquingKeysWith: { first, _ in first })
        let task = Task.detached(priority: .utility) {
            let classifier = ExerciseClassifier(seedCorpus: seedCorpus)
            var classifications: [UUID: ExerciseClassification] = [:]
            classifications.reserveCapacity(namesByID.count)
            for (id, name) in namesByID {
                guard !Task.isCancelled else { return classifications }
                classifications[id] = classifier.classify(name: name)
            }
            return classifications
        }
        let classifications = await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        guard !Task.isCancelled,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }

        let candidateIDs = candidates.map(\.id)
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        let transactionCandidates: [ExerciseLibraryModel]
        do {
            let ids = candidateIDs
            transactionCandidates = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>(
                predicate: #Predicate { ids.contains($0.id) }
            ))
        } catch {
            transaction.rollback()
            return
        }

        var didChange = false
        for exercise in transactionCandidates {
            guard !Task.isCancelled,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }
            // Classification runs off-main. Re-check the live row before
            // applying it so an approval, edit, discard, or ownership change
            // made while that work was running always wins.
            guard exercise.ownerID != nil,
                  exercise.deletedAt == nil,
                  exercise.importBatchID != nil,
                  exercise.userModified == false,
                  exercise.classificationSource != .manual else { continue }
            guard let classification = classifications[exercise.id] else { continue }
            exercise.primaryMuscles = classification.primaryMuscles
            exercise.secondaryMuscles = classification.secondaryMuscles
            exercise.movementPattern = classification.movementPattern
            exercise.equipment = classification.equipment ?? exercise.equipment
            exercise.isCardio = classification.isCardio
            exercise.category = classification.isCardio ? "cardio" : "strength"
            exercise.classificationSource = classification.source
            exercise.classificationConfidence = classification.confidence
            exercise.needsReview = classification.confidence < ExerciseClassifier.reviewConfidenceThreshold
            exercise.importedRawName = exercise.importedRawName ?? exercise.name
            exercise.updatedAt = Date()
            didChange = true
        }

        if didChange {
            do {
                try save(transaction)
            } catch {
                transaction.rollback()
                // Do not stamp the migration. A later launch/idle window must
                // retry rather than permanently suppressing unsaved changes.
                return
            }
        }
        defaults.set(true, forKey: didRunKey)

        if classifications.values.contains(where: {
            $0.confidence < ExerciseClassifier.reviewConfidenceThreshold
        }),
           LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork {
            ExerciseAIClassifier.scheduleRefinement(in: transaction)
        }
    }
}
