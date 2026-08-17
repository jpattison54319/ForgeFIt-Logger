import Foundation
import ForgeCore
import ForgeData
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Tier 4 of exercise classification: an on-device Apple Intelligence pass that
/// refines the muscle/type guesses for exercises the cheap tiers weren't
/// confident about. Runs in the background after an import (and on backfill),
/// never on the main import path. Degrades to a no-op when Apple Intelligence is
/// unavailable — those exercises simply stay in the review queue.
///
/// It improves the pre-filled guess but does NOT clear `needsReview`: an item
/// that needed the LLM is exactly one we still want the user to glance at, and
/// confirming a good guess is a single tap in the review screen.
@MainActor
enum ExerciseAIClassifier {
    static var isSupported: Bool { AICoach.isSupported }

    private struct RefinementOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private static var activeOperation: RefinementOperation?
    private static var cancelledOperation: RefinementOperation?
    private static var pendingContext: ModelContext?
    private static var pendingRevision = 0
    private static var isLiveWorkoutActive = false

    /// Keeps the optional Apple Intelligence refinement off the interaction
    /// path while preserving the request for one retry after the workout.
    static func scheduleRefinement(in context: ModelContext) {
        guard isSupported else { return }
        pendingContext = context
        pendingRevision &+= 1
        startPendingRefinementIfAllowed()
    }

    static func setLiveWorkoutActive(_ isActive: Bool) {
        guard isLiveWorkoutActive != isActive else { return }
        isLiveWorkoutActive = isActive
        if isActive {
            if let activeOperation {
                cancelledOperation = activeOperation
                activeOperation.task.cancel()
            }
            activeOperation = nil
        } else {
            startPendingRefinementIfAllowed()
        }
    }

    static func cancelAll() {
        activeOperation?.task.cancel()
        cancelledOperation?.task.cancel()
        activeOperation = nil
        cancelledOperation = nil
        pendingContext = nil
        pendingRevision &+= 1
    }

    private static func startPendingRefinementIfAllowed() {
        guard !isLiveWorkoutActive,
              activeOperation == nil,
              let context = pendingContext else { return }

        let prior = cancelledOperation
        let revision = pendingRevision
        let id = UUID()
        let task = Task { @MainActor in
            if let prior { await prior.task.value }
            guard !Task.isCancelled, !isLiveWorkoutActive else { return }
            await refineFlaggedExercises(in: context)
            guard !Task.isCancelled, !isLiveWorkoutActive else { return }
            if activeOperation?.id == id {
                activeOperation = nil
                if cancelledOperation?.id == prior?.id {
                    cancelledOperation = nil
                }
                if pendingRevision == revision {
                    pendingContext = nil
                } else {
                    // Another import arrived after this pass captured its
                    // candidates. Run once more so those newer rows are not
                    // silently left behind.
                    startPendingRefinementIfAllowed()
                }
            }
        }
        activeOperation = RefinementOperation(id: id, task: task)
    }

    /// Classify up to `limit` still-flagged custom exercises that haven't already
    /// been touched by the AI or the user.
    static func refineFlaggedExercises(in context: ModelContext, limit: Int = 40) async {
        guard isSupported,
              !isLiveWorkoutActive,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              !Task.isCancelled else { return }

        let aiRaw = ClassificationSource.ai.rawValue
        let manualRaw = ClassificationSource.manual.rawValue
        let descriptor: FetchDescriptor<ExerciseLibraryModel> = FetchDescriptor(
            predicate: #Predicate { exercise in
                exercise.needsReview == true
                    && exercise.ownerID != nil
                    && exercise.deletedAt == nil
            }
        )
        guard let flagged = try? context.fetch(descriptor).filter({
            $0.classificationSourceRaw != aiRaw && $0.classificationSourceRaw != manualRaw
        }), !flagged.isEmpty else { return }

        // Keep model mutation transactional with respect to lifecycle
        // cancellation. Model calls can suspend for seconds; collecting value
        // results first prevents a half-refined main context from being swept
        // into a live-workout save if the session starts between calls.
        var guesses: [UUID: AIGuess] = [:]
        for exercise in flagged.prefix(limit) {
            guard !isLiveWorkoutActive,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
                  !Task.isCancelled else { return }
            let name = exercise.importedRawName ?? exercise.name
            guard let guess = await classify(name: name) else { continue }
            guard !isLiveWorkoutActive,
                  LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
                  !Task.isCancelled else { return }
            guesses[exercise.id] = guess
        }

        guard !isLiveWorkoutActive,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              !Task.isCancelled else { return }
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        let guessIDs = Array(guesses.keys)
        guard let candidates = try? transaction.fetch(FetchDescriptor<ExerciseLibraryModel>(
            predicate: #Predicate { guessIDs.contains($0.id) }
        )) else { return }
        var didChange = false
        for exercise in candidates {
            guard let guess = guesses[exercise.id] else { continue }
            let primary = guess.sanitizedPrimary
            guard !primary.isEmpty else { continue }

            exercise.primaryMuscles = primary
            exercise.secondaryMuscles = guess.sanitizedSecondary(excluding: primary)
            exercise.isCardio = guess.isCardio
            if guess.isCardio {
                exercise.category = "cardio"
                exercise.movementPattern = "cardio"
                exercise.defaultWeightMode = WeightMode.bodyweight
            }
            exercise.classificationSource = ClassificationSource.ai
            exercise.classificationConfidence = max(exercise.classificationConfidence, 0.8)
            exercise.updatedAt = Date()
            didChange = true
        }
        guard !isLiveWorkoutActive,
              LiveWorkoutPerformanceGate.shared.allowsNonWorkoutWork,
              !Task.isCancelled else { return }
        if didChange {
            do {
                try transaction.save()
            } catch {
                transaction.rollback()
            }
        }
    }

    // MARK: - Model call

    private struct AIGuess: Decodable {
        var isCardio: Bool
        var primaryMuscles: [String]
        var secondaryMuscles: [String]

        var sanitizedPrimary: [String] { Self.valid(primaryMuscles) }
        func sanitizedSecondary(excluding primary: [String]) -> [String] {
            Self.valid(secondaryMuscles).filter { !primary.contains($0) }
        }

        private static let allowed = Set(ExerciseCatalog.muscleGroups)
        private static func valid(_ muscles: [String]) -> [String] {
            var seen = Set<String>()
            return muscles
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                .filter { allowed.contains($0) && seen.insert($0).inserted }
        }
    }

    private static func classify(name: String) async -> AIGuess? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let muscleList = ExerciseCatalog.muscleGroups.joined(separator: ", ")
        let instructions = """
        You are a strength-and-conditioning taxonomy expert. Given a single exercise \
        name, identify whether it is a cardio/conditioning exercise and which muscles it \
        trains. Choose muscles ONLY from this exact list: \(muscleList). Use "cardiovascular" \
        as the first primary muscle for cardio exercises. Primary muscles are the main \
        movers (usually 1–3); secondary are assisting muscles.

        Respond with STRICT JSON and nothing else, in this exact shape:
        {"isCardio": false, "primaryMuscles": ["..."], "secondaryMuscles": ["..."]}
        If you are unsure, return your best guess. Never invent muscle names outside the list.
        """
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Exercise name: \(name)")
            return decode(response.content)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Pull the first JSON object out of the model's reply (tolerating code
    /// fences or stray prose) and decode it.
    private static func decode(_ raw: String) -> AIGuess? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let json = String(raw[start...end])
        return try? JSONDecoder().decode(AIGuess.self, from: Data(json.utf8))
    }
}
