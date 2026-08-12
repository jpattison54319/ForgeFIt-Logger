import Foundation
import ForgeCore
import ForgeData
import SwiftData

@MainActor
enum ImportedExerciseBackfill {
    private static let didRunKey = "importedExerciseClassificationBackfill.v1.didRun"

    static func runIfNeeded(in context: ModelContext) async {
        guard LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              !UserDefaults.standard.bool(forKey: didRunKey) else { return }

        let descriptor = FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { exercise in
                exercise.ownerID != nil
                    && exercise.deletedAt == nil
                    && exercise.isCardio == false
            }
        )
        let candidates = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.primaryMuscles.isEmpty }

        guard !candidates.isEmpty else {
            UserDefaults.standard.set(true, forKey: didRunKey)
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

        var didChange = false
        for exercise in candidates {
            guard !Task.isCancelled,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork else { return }
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
            try? context.save()
        }
        UserDefaults.standard.set(true, forKey: didRunKey)

        if candidates.contains(where: \.needsReview),
           LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork {
            ExerciseAIClassifier.scheduleRefinement(in: context)
        }
    }
}
