import Foundation
import ForgeCore
import ForgeData
import SwiftData

@MainActor
enum ImportedExerciseBackfill {
    static let didRunKey = "importedExerciseClassificationBackfill.v2.didRun"

    private nonisolated struct CooperativeReceipt: Sendable {
        let needsAIRefinement: Bool
    }

    /// Launch/foreground variant: candidate fetch, classification, guarded
    /// re-fetch, mutation, and save all run in isolated contexts away from the
    /// UI actor. Only completion metadata returns; the defaults stamp remains
    /// MainActor-owned and is written only after a durable worker success.
    static func runCooperativelyIfNeeded(
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) async {
        guard LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              !defaults.bool(forKey: didRunKey) else { return }

        let container = context.container
        let task = Task.detached(priority: .utility) {
            try runPersisted(in: container)
        }
        do {
            let receipt = try await withTaskCancellationHandler(
                operation: { try await task.value },
                onCancel: { task.cancel() }
            )
            guard !Task.isCancelled,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }
            defaults.set(true, forKey: didRunKey)
            if receipt.needsAIRefinement {
                ExerciseAIClassifier.scheduleRefinement(in: context)
            }
        } catch {
            // A cancelled or failed read/save stays unstamped and retries in a
            // later idle foreground window.
        }
    }

    private nonisolated static func runPersisted(
        in container: ModelContainer
    ) throws -> CooperativeReceipt {
        try Task.checkCancellation()
        let snapshotContext = ModelContext(container)
        snapshotContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { exercise in
                exercise.ownerID != nil
                    && exercise.deletedAt == nil
                    && exercise.importBatchID != nil
                    && exercise.userModified == false
            }
        )
        let candidates = try snapshotContext.fetch(descriptor)
        guard !candidates.isEmpty else {
            return CooperativeReceipt(needsAIRefinement: false)
        }

        let namesByID = Dictionary(
            candidates.map { ($0.id, $0.importedRawName ?? $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let classifier = ExerciseClassifier(
            seedCorpus: ExerciseCatalog.classificationSeedCorpusForWorker()
        )
        var classifications: [UUID: ExerciseClassification] = [:]
        classifications.reserveCapacity(namesByID.count)
        for (id, name) in namesByID {
            try Task.checkCancellation()
            classifications[id] = classifier.classify(name: name)
        }

        try Task.checkCancellation()
        let transaction = ModelContext(container)
        transaction.autosaveEnabled = false
        do {
            let candidateIDs = Array(namesByID.keys)
            let transactionCandidates = try transaction.fetch(FetchDescriptor<ExerciseLibraryModel>(
                predicate: #Predicate { candidateIDs.contains($0.id) }
            ))
            var didChange = false
            for exercise in transactionCandidates {
                try Task.checkCancellation()
                // A user can approve/edit/discard while classification runs.
                // The fresh-context re-check keeps that newer decision
                // authoritative over this maintenance pass.
                guard exercise.ownerID != nil,
                      exercise.deletedAt == nil,
                      exercise.importBatchID != nil,
                      exercise.userModified == false,
                      exercise.classificationSource != .manual,
                      let classification = classifications[exercise.id] else { continue }
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
            try Task.checkCancellation()
            if didChange {
                try transaction.save()
            }
        } catch {
            transaction.rollback()
            throw error
        }

        return CooperativeReceipt(needsAIRefinement: classifications.values.contains {
            $0.confidence < ExerciseClassifier.reviewConfidenceThreshold
        })
    }

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
