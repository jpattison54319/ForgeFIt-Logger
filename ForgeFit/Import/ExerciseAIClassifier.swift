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

    /// Classify up to `limit` still-flagged custom exercises that haven't already
    /// been touched by the AI or the user.
    static func refineFlaggedExercises(in context: ModelContext, limit: Int = 40) async {
        guard isSupported else { return }

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

        var didChange = false
        for exercise in flagged.prefix(limit) {
            let name = exercise.importedRawName ?? exercise.name
            guard let guess = await classify(name: name) else { continue }
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
        if didChange { try? context.save() }
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
