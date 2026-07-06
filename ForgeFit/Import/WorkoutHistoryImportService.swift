import Foundation
import ForgeCore
import ForgeData
import SwiftData

nonisolated struct ExerciseImportMatch: Identifiable, Hashable, Sendable {
    var id: String { importedName }
    var importedName: String
    var exerciseID: UUID?
    var exerciseName: String?
    var score: Int
    var willCreateCustom: Bool { exerciseID == nil }
}

nonisolated struct WorkoutHistoryImportPreview: Sendable {
    var parseResult: WorkoutHistoryImportParseResult
    var matches: [ExerciseImportMatch]
    var duplicateCount: Int
    /// Best-effort muscle/type classification for each imported name that will be
    /// created as a custom exercise, keyed by imported name.
    var classifications: [String: ExerciseClassification]
    var importableCount: Int { parseResult.workouts.count - duplicateCount }
    var customExerciseCount: Int { matches.filter(\.willCreateCustom).count }
    var flaggedForReviewCount: Int {
        matches.filter(\.willCreateCustom).filter {
            (classifications[$0.importedName]?.confidence ?? 0) < ExerciseClassifier.reviewConfidenceThreshold
        }.count
    }

    var dateRange: ClosedRange<Date>? {
        guard let first = parseResult.workouts.map(\.startedAt).min(),
              let last = parseResult.workouts.map(\.startedAt).max() else { return nil }
        return first...last
    }
}

nonisolated struct WorkoutHistoryImportCommitResult {
    var importedWorkouts: Int
    var skippedDuplicates: Int
    var createdExercises: Int
    var flaggedForReview: Int
    var warningCount: Int
}

@MainActor
enum WorkoutHistoryImportService {
    /// Parse + match + classify. The heavy CPU work (parsing, fuzzy matching,
    /// on-device muscle classification) runs off the main actor on `Sendable`
    /// value types; only lightweight snapshotting happens on the main actor.
    static func preview(
        data: Data,
        fileName: String,
        workouts existingWorkouts: [WorkoutModel],
        exercises: [ExerciseLibraryModel]
    ) async throws -> WorkoutHistoryImportPreview {
        let existingFingerprints = Set(existingWorkouts.compactMap(\.importFingerprint))
        let userExercises = exercises.map(\.domainInfo)
        let seedCorpus = seedCorpus()
        return try await Task.detached(priority: .userInitiated) {
            try makePreview(
                data: data,
                fileName: fileName,
                existingFingerprints: existingFingerprints,
                userExercises: userExercises,
                seedCorpus: seedCorpus
            )
        }.value
    }

    /// Pure, actor-agnostic core of `preview`, usable from a background task and
    /// directly testable without a `ModelContext`.
    nonisolated static func makePreview(
        data: Data,
        fileName: String,
        existingFingerprints: Set<String>,
        userExercises: [ExerciseInfo],
        seedCorpus: [ExerciseInfo]
    ) throws -> WorkoutHistoryImportPreview {
        let parsed = try WorkoutHistoryImportParser.parse(data: data, fileName: fileName)
        let duplicateCount = parsed.workouts.filter { existingFingerprints.contains($0.fingerprint) }.count
        let matches = matchExercises(for: parsed.workouts, userExercises: userExercises)
        let classifications = classifyUnmatched(matches: matches, workouts: parsed.workouts, seedCorpus: seedCorpus)
        return WorkoutHistoryImportPreview(
            parseResult: parsed,
            matches: matches,
            duplicateCount: duplicateCount,
            classifications: classifications
        )
    }

    @discardableResult
    static func commit(
        preview: WorkoutHistoryImportPreview,
        workouts existingWorkouts: [WorkoutModel],
        exercises existingExercises: [ExerciseLibraryModel],
        in context: ModelContext
    ) throws -> WorkoutHistoryImportCommitResult {
        let userID = ForgeFitDemo.userID
        let existingFingerprints = Set(existingWorkouts.compactMap(\.importFingerprint))
        let existingExternalKeys = Set(existingWorkouts.compactMap { workout -> String? in
            guard let source = workout.externalSource, let externalID = workout.externalWorkoutID else { return nil }
            return "\(source)|\(externalID)"
        })

        let source = preview.parseResult.source
        let batch = WorkoutImportBatchModel(
            userID: userID,
            source: source.displayName,
            fileName: preview.parseResult.fileName,
            importedCount: 0,
            skippedDuplicateCount: 0,
            warningCount: preview.parseResult.warnings.count,
            startedAt: preview.parseResult.workouts.map(\.startedAt).min(),
            endedAt: preview.parseResult.workouts.map(\.startedAt).max()
        )
        context.insert(batch)

        var exerciseByImportedName = Dictionary(uniqueKeysWithValues: preview.matches.compactMap { match -> (String, UUID)? in
            guard let exerciseID = match.exerciseID else { return nil }
            return (match.importedName, exerciseID)
        })
        var exerciseByID = Dictionary(uniqueKeysWithValues: existingExercises.map { ($0.id, $0) })
        var createdExercises = 0
        var flaggedForReview = 0
        var importedWorkouts = 0
        var skipped = 0

        for draft in preview.parseResult.workouts {
            let externalKey = draft.externalID.map { "\(source.rawValue)|\($0)" }
            if existingFingerprints.contains(draft.fingerprint) || externalKey.map(existingExternalKeys.contains) == true {
                skipped += 1
                continue
            }

            var workoutExercises: [WorkoutExerciseModel] = []
            var cardioSessions: [CardioSessionModel] = []

            for (position, exerciseDraft) in draft.exercises.enumerated() {
                let exerciseID: UUID
                if let matchedID = exerciseByImportedName[exerciseDraft.name],
                   exerciseByID[matchedID] != nil {
                    exerciseID = matchedID
                } else {
                    let classification = preview.classifications[exerciseDraft.name]
                    let created = makeCustomExercise(
                        from: exerciseDraft,
                        classification: classification,
                        batchID: batch.id,
                        userID: userID
                    )
                    context.insert(created)
                    exerciseByID[created.id] = created
                    exerciseByImportedName[exerciseDraft.name] = created.id
                    exerciseID = created.id
                    createdExercises += 1
                    if created.needsReview { flaggedForReview += 1 }
                }

                let exercise = exerciseByID[exerciseID]
                let cardioSets = exerciseDraft.sets.filter { isCardioSet($0, exerciseName: exerciseDraft.name, exercise: exercise) }
                let strengthSets = exerciseDraft.sets.filter { !isCardioSet($0, exerciseName: exerciseDraft.name, exercise: exercise) }

                let workoutExercise = WorkoutExerciseModel(
                    userID: userID,
                    exerciseID: exerciseID,
                    position: position,
                    supersetGroup: exerciseDraft.supersetID,
                    notes: exerciseDraft.notes
                )

                workoutExercise.sets = strengthSets.enumerated().map { setPosition, setDraft in
                    SetModel(
                        userID: userID,
                        position: setPosition,
                        setType: setDraft.setType,
                        weightMode: exercise?.defaultWeightMode ?? .external,
                        reps: setDraft.reps,
                        weight: setDraft.weightKg,
                        rpe: setDraft.rpe,
                        durationSeconds: setDraft.durationSeconds,
                        completedAt: draft.endedAt
                    )
                }
                workoutExercises.append(workoutExercise)

                if !cardioSets.isEmpty {
                    let duration = cardioSets.compactMap(\.durationSeconds).reduce(0, +)
                    let distance = cardioSets.compactMap(\.distanceMeters).reduce(0, +)
                    let kind = CardioKind.infer(name: exerciseDraft.name, equipment: exercise?.equipment)
                    let session = CardioSessionModel(
                        userID: userID,
                        workoutExerciseID: workoutExercise.id,
                        modality: kind.rawValue,
                        startedAt: draft.startedAt,
                        liveStartedAt: draft.startedAt,
                        endedAt: draft.endedAt,
                        sourceDevice: "import-\(source.rawValue)",
                        durationSeconds: duration > 0 ? duration : max(0, Int(draft.endedAt.timeIntervalSince(draft.startedAt))),
                        distanceMeters: distance > 0 ? distance : nil,
                        avgPaceSecondsPerKm: CardioMetrics.paceSecPerKm(
                            distanceMeters: distance > 0 ? distance : nil,
                            durationSeconds: duration > 0 ? duration : nil
                        )
                    )
                    cardioSessions.append(session)
                }
            }

            let workout = WorkoutModel(
                userID: userID,
                title: draft.title,
                startedAt: draft.startedAt,
                endedAt: draft.endedAt,
                sourceDevice: "import-\(source.rawValue)",
                notes: draft.notes,
                externalSource: source.rawValue,
                externalWorkoutID: draft.externalID,
                importFingerprint: draft.fingerprint,
                importBatchID: batch.id,
                exercises: workoutExercises,
                cardioSessions: cardioSessions
            )
            workout.recomputeTotalVolume()
            context.insert(workout)
            importedWorkouts += 1
        }

        batch.importedCount = importedWorkouts
        batch.skippedDuplicateCount = skipped
        try context.save()
        if flaggedForReview > 0 {
            Task { @MainActor in
                await ExerciseAIClassifier.refineFlaggedExercises(in: context)
            }
        }

        return WorkoutHistoryImportCommitResult(
            importedWorkouts: importedWorkouts,
            skippedDuplicates: skipped,
            createdExercises: createdExercises,
            flaggedForReview: flaggedForReview,
            warningCount: preview.parseResult.warnings.count
        )
    }

    // MARK: - Matching & classification (pure)

    nonisolated private static func matchExercises(
        for workouts: [ImportedWorkoutDraft],
        userExercises: [ExerciseInfo]
    ) -> [ExerciseImportMatch] {
        let snapshot = ExerciseLibrarySnapshot(exercises: userExercises)
        let names = Array(Set(workouts.flatMap { $0.exercises.map(\.name) })).sorted()
        return names.map { name in
            let result = snapshot.search(name, limit: 1).first
            if let result, result.score >= 75 {
                return ExerciseImportMatch(
                    importedName: name,
                    exerciseID: result.exercise.id,
                    exerciseName: result.exercise.name,
                    score: result.score
                )
            }
            return ExerciseImportMatch(importedName: name, exerciseID: nil, exerciseName: nil, score: result?.score ?? 0)
        }
    }

    /// Classify every imported name that will become a new custom exercise.
    nonisolated private static func classifyUnmatched(
        matches: [ExerciseImportMatch],
        workouts: [ImportedWorkoutDraft],
        seedCorpus: [ExerciseInfo]
    ) -> [String: ExerciseClassification] {
        let unmatched = Set(matches.filter(\.willCreateCustom).map(\.importedName))
        guard !unmatched.isEmpty else { return [:] }

        // Aggregate a metrics hint per imported name across all its logged sets.
        var hints: [String: ExerciseClassificationHint] = [:]
        for exercise in workouts.flatMap(\.exercises) where unmatched.contains(exercise.name) {
            var hint = hints[exercise.name] ?? ExerciseClassificationHint()
            for set in exercise.sets {
                if set.distanceMeters != nil { hint.hasDistance = true }
                if set.weightKg != nil { hint.hasWeight = true }
                if set.reps != nil { hint.hasReps = true }
            }
            hints[exercise.name] = hint
        }

        let classifier = ExerciseClassifier(seedCorpus: seedCorpus)
        var result: [String: ExerciseClassification] = [:]
        for name in unmatched {
            result[name] = classifier.classify(name: name, hint: hints[name] ?? ExerciseClassificationHint())
        }
        return result
    }

    /// Snapshot of the bundled seed library as pure `ExerciseInfo` for the
    /// classifier to borrow muscle data from.
    static func seedCorpus() -> [ExerciseInfo] {
        ExerciseCatalog.load().map { seed in
            ExerciseInfo(
                id: ExerciseCatalog.deterministicID(for: seed.slug),
                name: seed.name,
                movementPattern: seed.force,
                primaryMuscles: seed.primaryMuscles,
                secondaryMuscles: seed.secondaryMuscles,
                equipment: seed.equipment
            )
        }
    }

    // MARK: - Custom exercise creation

    nonisolated static func makeCustomExercise(
        from draft: ImportedExerciseDraft,
        classification: ExerciseClassification?,
        batchID: UUID?,
        userID: UUID
    ) -> ExerciseLibraryModel {
        // Fall back to the legacy cardio-keyword heuristic if the classifier was
        // absent (e.g. an empty seed corpus in a test).
        let resolved = classification ?? legacyClassification(for: draft)
        let confident = resolved.confidence >= ExerciseClassifier.reviewConfidenceThreshold
        let equipment = resolved.equipment ?? ExerciseClassifier.inferredEquipment(name: draft.name.lowercased())

        return ExerciseLibraryModel(
            ownerID: userID,
            name: draft.name,
            movementPattern: resolved.isCardio ? "cardio" : resolved.movementPattern,
            primaryMuscles: resolved.primaryMuscles,
            secondaryMuscles: resolved.secondaryMuscles,
            equipment: equipment,
            defaultWeightMode: resolved.isCardio ? .bodyweight : .external,
            isCardio: resolved.isCardio,
            category: resolved.isCardio ? "cardio" : "strength",
            needsReview: !confident,
            classificationConfidence: resolved.confidence,
            classificationSourceRaw: resolved.source.rawValue,
            importBatchID: batchID,
            importedRawName: draft.name
        )
    }

    /// Minimal cardio-only classification used when no seed-backed classifier is
    /// available; mirrors the previous `makeCustomExercise` behaviour.
    nonisolated private static func legacyClassification(for draft: ImportedExerciseDraft) -> ExerciseClassification {
        let kind = CardioKind.infer(name: draft.name, equipment: nil)
        let hasCardioMetrics = draft.sets.contains { $0.distanceMeters != nil }
        let isCardio = kind != .other || hasCardioMetrics
        return ExerciseClassification(
            primaryMuscles: isCardio ? kind.musclesWorked : [],
            isCardio: isCardio,
            movementPattern: isCardio ? "cardio" : nil,
            cardioModality: isCardio ? kind.rawValue : nil,
            confidence: isCardio ? 0.8 : 0,
            source: isCardio ? .keyword : .fallback
        )
    }

    nonisolated private static func isCardioSet(_ set: ImportedSetDraft, exerciseName: String, exercise: ExerciseLibraryModel?) -> Bool {
        if set.distanceMeters != nil { return true }
        if exercise?.isCardio == true { return true }
        let kind = CardioKind.infer(name: exerciseName, equipment: exercise?.equipment)
        return kind != .other && set.reps == nil && set.weightKg == nil
    }
}
