import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Where an exercise's muscle/type classification came from. Ordered loosely by
/// trust: deterministic keyword hits are trusted; fuzzy/vector guesses are
/// best-effort and get flagged for the user to confirm.
public enum ClassificationSource: String, Codable, Sendable {
    case matchedLibrary   // reused an existing library exercise; no custom created
    case keyword          // deterministic keyword/regex map
    case seedFuzzy        // borrowed muscles from a fuzzy seed-library match
    case embedding        // NLEmbedding nearest-neighbour in the seed library
    case ai               // on-device Apple Intelligence classification
    case manual           // user confirmed/edited
    case fallback         // nothing matched; empty guess
}

/// Result of classifying an imported exercise name into muscles + type. Pure
/// value type so it can cross actor boundaries out of a background task.
public struct ExerciseClassification: Sendable, Equatable {
    public var primaryMuscles: [String]
    public var secondaryMuscles: [String]
    public var isCardio: Bool
    public var movementPattern: String?
    public var equipment: String?
    /// A `CardioKind` raw value (run, cycle, row, …) when `isCardio`; else nil.
    public var cardioModality: String?
    public var confidence: Double
    public var source: ClassificationSource

    public init(
        primaryMuscles: [String] = [],
        secondaryMuscles: [String] = [],
        isCardio: Bool = false,
        movementPattern: String? = nil,
        equipment: String? = nil,
        cardioModality: String? = nil,
        confidence: Double = 0,
        source: ClassificationSource = .fallback
    ) {
        self.primaryMuscles = primaryMuscles
        self.secondaryMuscles = secondaryMuscles
        self.isCardio = isCardio
        self.movementPattern = movementPattern
        self.equipment = equipment
        self.cardioModality = cardioModality
        self.confidence = confidence
        self.source = source
    }
}

/// Small hint derived from an imported exercise's logged sets, used to
/// disambiguate cardio from strength (distance-only sets read as cardio).
public struct ExerciseClassificationHint: Sendable, Equatable {
    public var hasDistance: Bool
    public var hasReps: Bool
    public var hasWeight: Bool

    public init(hasDistance: Bool = false, hasReps: Bool = false, hasWeight: Bool = false) {
        self.hasDistance = hasDistance
        self.hasReps = hasReps
        self.hasWeight = hasWeight
    }
}

/// Tiered, on-device classifier that maps a raw exercise name to primary /
/// secondary muscles and a strength-vs-cardio type. Tiers run cheapest-first and
/// stop as soon as one is confident; the best-effort guess is always returned so
/// callers can store it and flag low-confidence results for review.
///
/// Not `Sendable` — construct and use a single instance inside a background task.
/// Inputs (`[ExerciseInfo]`, names) and the `ExerciseClassification` output are
/// value types that cross the actor boundary safely.
public final class ExerciseClassifier {
    /// Guesses at or above this confidence are trusted; below it callers should
    /// set `needsReview = true`.
    public static let reviewConfidenceThreshold = 0.8

    private let seedCorpus: [ExerciseInfo]
    private let snapshot: ExerciseLibrarySnapshot

    // Lazily-built embedding index (only when tier 3 is actually reached).
    private var embeddingIndexBuilt = false
    #if canImport(NaturalLanguage)
    private var embedding: NLEmbedding?
    private var embeddingVectors: [(exercise: ExerciseInfo, vector: [Double])] = []
    #endif

    public init(seedCorpus: [ExerciseInfo]) {
        // Only strength/named seeds are useful for borrowing muscle data.
        self.seedCorpus = seedCorpus
        self.snapshot = ExerciseLibrarySnapshot(exercises: seedCorpus)
    }

    // MARK: - Public API

    public func classify(name rawName: String, hint: ExerciseClassificationHint = .init()) -> ExerciseClassification {
        let name = Self.normalized(rawName)
        guard !name.isEmpty else {
            return ExerciseClassification(confidence: 0, source: .fallback)
        }

        // Tier 0 — cardio detection short-circuits muscle logic.
        if let cardio = cardioClassification(name: name, hint: hint) {
            return cardio
        }

        var best = ExerciseClassification(confidence: 0, source: .fallback)

        // Tier 1 — keyword map.
        if let keyword = keywordClassification(name: name) {
            if keyword.confidence >= Self.reviewConfidenceThreshold { return keyword }
            if keyword.confidence > best.confidence { best = keyword }
        }

        // Tier 2 — fuzzy borrow from the seed library.
        if let fuzzy = fuzzyClassification(rawName: rawName) {
            if fuzzy.confidence >= Self.reviewConfidenceThreshold { return fuzzy }
            if fuzzy.confidence > best.confidence { best = fuzzy }
        }

        // Tier 3 — embedding nearest-neighbour (only if still uncertain).
        if let vector = embeddingClassification(rawName: rawName), vector.confidence > best.confidence {
            best = vector
        }

        return best
    }

    // MARK: - Tier 0: cardio

    private func cardioClassification(name: String, hint: ExerciseClassificationHint) -> ExerciseClassification? {
        var modality: String?
        for rule in Self.cardioRules where rule.keywords.contains(where: { name.contains($0) }) {
            modality = rule.modality
            return ExerciseClassification(
                primaryMuscles: rule.primary,
                secondaryMuscles: rule.secondary,
                isCardio: true,
                movementPattern: "cardio",
                equipment: rule.equipment,
                cardioModality: rule.modality,
                confidence: 0.9,
                source: .keyword
            )
        }
        // Distance-only logged sets with no load strongly imply cardio.
        if hint.hasDistance && !hint.hasWeight {
            let fallback = Self.cardioRules.first { $0.modality == "other" }
            return ExerciseClassification(
                primaryMuscles: fallback?.primary ?? ["cardiovascular"],
                secondaryMuscles: fallback?.secondary ?? [],
                isCardio: true,
                movementPattern: "cardio",
                equipment: modality,
                cardioModality: "other",
                confidence: 0.7,
                source: .keyword
            )
        }
        return nil
    }

    // MARK: - Tier 1: keyword

    private func keywordClassification(name: String) -> ExerciseClassification? {
        for rule in Self.keywordRules where rule.keywords.contains(where: { name.contains($0) }) {
            return ExerciseClassification(
                primaryMuscles: rule.primary,
                secondaryMuscles: rule.secondary,
                isCardio: false,
                equipment: Self.inferredEquipment(name: name),
                confidence: 0.9,
                source: .keyword
            )
        }
        return nil
    }

    // MARK: - Tier 2: fuzzy borrow

    private func fuzzyClassification(rawName: String) -> ExerciseClassification? {
        guard let result = snapshot.search(rawName, limit: 1).first, result.score >= 58 else { return nil }
        let seed = result.exercise
        guard !seed.primaryMuscles.isEmpty else { return nil }
        // Map the 0–100 fuzzy score into a confidence band. Kept below the review
        // threshold except for very strong matches so borrowed guesses get a look.
        let confidence: Double
        switch result.score {
        case 90...:  confidence = 0.85
        case 72..<90: confidence = 0.75
        case 65..<72: confidence = 0.65
        default:      confidence = 0.55
        }
        return ExerciseClassification(
            primaryMuscles: seed.primaryMuscles,
            secondaryMuscles: seed.secondaryMuscles,
            isCardio: false,
            movementPattern: seed.movementPattern,
            equipment: seed.equipment ?? Self.inferredEquipment(name: Self.normalized(rawName)),
            confidence: confidence,
            source: .seedFuzzy
        )
    }

    // MARK: - Tier 3: embeddings

    private func embeddingClassification(rawName: String) -> ExerciseClassification? {
        #if canImport(NaturalLanguage)
        buildEmbeddingIndexIfNeeded()
        guard let embedding, let query = embedding.vector(for: Self.normalized(rawName)) else { return nil }
        var bestSim = -1.0
        var bestSeed: ExerciseInfo?
        for entry in embeddingVectors {
            let sim = Self.cosineSimilarity(query, entry.vector)
            if sim > bestSim {
                bestSim = sim
                bestSeed = entry.exercise
            }
        }
        guard let seed = bestSeed, bestSim >= 0.5, !seed.primaryMuscles.isEmpty else { return nil }
        // Cosine 0.5→0.0 conf, 1.0→0.78 conf. Capped below the review threshold so
        // embedding-only guesses are always flagged.
        let confidence = min(0.78, max(0, (bestSim - 0.5) / 0.5 * 0.78))
        return ExerciseClassification(
            primaryMuscles: seed.primaryMuscles,
            secondaryMuscles: seed.secondaryMuscles,
            isCardio: false,
            movementPattern: seed.movementPattern,
            equipment: seed.equipment,
            confidence: confidence,
            source: .embedding
        )
        #else
        return nil
        #endif
    }

    #if canImport(NaturalLanguage)
    private func buildEmbeddingIndexIfNeeded() {
        guard !embeddingIndexBuilt else { return }
        embeddingIndexBuilt = true
        let model = NLEmbedding.sentenceEmbedding(for: .english) ?? NLEmbedding.wordEmbedding(for: .english)
        guard let model else { return }
        embedding = model
        embeddingVectors = seedCorpus.compactMap { seed in
            guard !seed.primaryMuscles.isEmpty,
                  let vector = model.vector(for: Self.normalized(seed.name)) else { return nil }
            return (seed, vector)
        }
    }

    private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return -1 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
    #endif

    // MARK: - Normalisation & equipment

    static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { result, character in
                if character == " ", result.last == " " { return }
                result.append(character)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func inferredEquipment(name: String) -> String? {
        if name.contains("barbell") { return "barbell" }
        if name.contains("dumbbell") { return "dumbbell" }
        if name.contains("cable") { return "cable" }
        if name.contains("machine") || name.contains("smith") || name.contains("hack") || name.contains("pec deck") { return "machine" }
        if name.contains("kettlebell") { return "kettlebells" }
        if name.contains("band") { return "bands" }
        if name.contains("ez bar") || name.contains("e z bar") || name.contains("ez curl") { return "e-z curl bar" }
        return nil
    }

    // MARK: - Rule tables

    private struct MuscleRule {
        let keywords: [String]
        let primary: [String]
        let secondary: [String]
    }

    private struct CardioRule {
        let keywords: [String]
        let primary: [String]
        let secondary: [String]
        let modality: String
        let equipment: String?
    }

    /// Cardio detection, most-specific first.
    private static let cardioRules: [CardioRule] = [
        CardioRule(keywords: ["treadmill", "jog", "sprint", "running", "run "], primary: ["cardiovascular", "quadriceps", "glutes"], secondary: ["hamstrings", "calves"], modality: "run", equipment: "treadmill"),
        CardioRule(keywords: ["trail run"], primary: ["cardiovascular", "quadriceps", "glutes"], secondary: ["hamstrings", "calves"], modality: "trailRun", equipment: nil),
        CardioRule(keywords: ["elliptical"], primary: ["cardiovascular", "quadriceps", "glutes"], secondary: ["hamstrings", "calves"], modality: "elliptical", equipment: "elliptical"),
        CardioRule(keywords: ["stair", "step mill", "stepmill", "stairmaster", "stair climber"], primary: ["cardiovascular", "quadriceps", "glutes"], secondary: ["calves"], modality: "stair", equipment: "stair"),
        CardioRule(keywords: ["jump rope", "jumprope", "skip rope", "skipping"], primary: ["cardiovascular", "calves"], secondary: ["shoulders"], modality: "jumpRope", equipment: nil),
        CardioRule(keywords: ["rower", "row erg", "rowing machine", "concept 2", "concept2", "ski erg", "skierg", "erg "], primary: ["cardiovascular", "lats", "upper back"], secondary: ["quadriceps", "biceps", "hamstrings"], modality: "row", equipment: "rower"),
        CardioRule(keywords: ["assault bike", "air bike", "spin bike", "spinning", "stationary bike", "cycling", "indoor cycle", "peloton"], primary: ["cardiovascular", "quadriceps"], secondary: ["glutes", "calves", "hamstrings"], modality: "cycle", equipment: "bike"),
        CardioRule(keywords: ["swim"], primary: ["cardiovascular", "lats", "shoulders"], secondary: ["upper back", "triceps"], modality: "swim", equipment: nil),
        CardioRule(keywords: ["hike", "hiking", "walk", "rucking", "ruck "], primary: ["cardiovascular", "quadriceps", "glutes"], secondary: ["hamstrings", "calves"], modality: "walk", equipment: nil),
    ]

    /// Strength keyword → muscles, most-specific first (compound names like
    /// "leg curl" must precede the generic "curl").
    private static let keywordRules: [MuscleRule] = [
        // Hamstrings / posterior
        MuscleRule(keywords: ["leg curl", "lying leg curl", "seated leg curl", "hamstring curl", "nordic curl"], primary: ["hamstrings"], secondary: ["calves"]),
        MuscleRule(keywords: ["romanian deadlift", "rdl", "stiff leg deadlift", "stiff-leg", "good morning"], primary: ["hamstrings", "glutes"], secondary: ["lower back"]),
        MuscleRule(keywords: ["deadlift"], primary: ["hamstrings", "glutes", "lower back"], secondary: ["forearms", "traps"]),
        MuscleRule(keywords: ["hip thrust", "glute bridge", "glute kickback", "glute"], primary: ["glutes"], secondary: ["hamstrings"]),
        MuscleRule(keywords: ["hyperextension", "back extension", "45 degree"], primary: ["lower back"], secondary: ["glutes", "hamstrings"]),
        // Quads
        MuscleRule(keywords: ["leg extension", "knee extension"], primary: ["quadriceps"], secondary: []),
        MuscleRule(keywords: ["leg press", "hack squat"], primary: ["quadriceps", "glutes"], secondary: ["hamstrings"]),
        MuscleRule(keywords: ["lunge", "split squat", "bulgarian", "step up", "step-up"], primary: ["quadriceps", "glutes"], secondary: ["hamstrings"]),
        MuscleRule(keywords: ["squat"], primary: ["quadriceps", "glutes"], secondary: ["hamstrings", "lower back"]),
        // Calves
        MuscleRule(keywords: ["calf raise", "calf press", "calf"], primary: ["calves"], secondary: []),
        // Shoulders
        MuscleRule(keywords: ["lateral raise", "side raise", "lat raise", "side lateral"], primary: ["shoulders"], secondary: []),
        MuscleRule(keywords: ["front raise"], primary: ["shoulders"], secondary: []),
        MuscleRule(keywords: ["rear delt", "reverse fly", "reverse flye", "face pull", "rear lateral"], primary: ["shoulders"], secondary: ["upper back", "traps"]),
        MuscleRule(keywords: ["overhead press", "shoulder press", "military press", "arnold press", "ohp", "push press"], primary: ["shoulders"], secondary: ["triceps"]),
        MuscleRule(keywords: ["upright row"], primary: ["shoulders", "traps"], secondary: []),
        MuscleRule(keywords: ["shrug"], primary: ["traps"], secondary: []),
        // Chest
        MuscleRule(keywords: ["bench press", "chest press", "chest fly", "chest flye", "pec deck", "pec fly", "cable fly", "cable crossover", "dumbbell fly", "incline press", "decline press", "bench"], primary: ["chest"], secondary: ["triceps", "shoulders"]),
        MuscleRule(keywords: ["push up", "pushup", "push-up"], primary: ["chest"], secondary: ["triceps", "shoulders"]),
        MuscleRule(keywords: ["dip"], primary: ["chest"], secondary: ["triceps", "shoulders"]),
        // Triceps
        MuscleRule(keywords: ["tricep", "triceps", "pushdown", "push down", "skull crusher", "skullcrusher", "kickback", "overhead extension", "close grip bench", "close-grip"], primary: ["triceps"], secondary: []),
        // Back / lats
        MuscleRule(keywords: ["pulldown", "lat pull", "pull up", "pullup", "pull-up", "chin up", "chin-up", "chinup"], primary: ["lats"], secondary: ["biceps", "upper back"]),
        MuscleRule(keywords: ["pullover"], primary: ["lats"], secondary: ["chest"]),
        MuscleRule(keywords: ["row"], primary: ["lats", "upper back"], secondary: ["biceps"]),
        // Biceps / forearms
        MuscleRule(keywords: ["hammer curl"], primary: ["biceps"], secondary: ["forearms"]),
        MuscleRule(keywords: ["wrist curl", "reverse curl", "forearm"], primary: ["forearms"], secondary: []),
        MuscleRule(keywords: ["curl", "bicep", "biceps", "preacher"], primary: ["biceps"], secondary: ["forearms"]),
        // Core
        MuscleRule(keywords: ["crunch", "sit up", "situp", "sit-up", "plank", "leg raise", "hanging", "russian twist", "ab wheel", "abs", "oblique", "toes to bar", "mountain climber"], primary: ["abdominals"], secondary: []),
    ]
}
