import Foundation

public struct ExerciseSearchResult: Equatable, Sendable {
    public var exercise: ExerciseInfo
    public var matchedText: String
    public var score: Int

    public init(exercise: ExerciseInfo, matchedText: String, score: Int) {
        self.exercise = exercise
        self.matchedText = matchedText
        self.score = score
    }
}

public struct ExerciseLibrarySnapshot: Equatable, Sendable {
    public var exercises: [ExerciseInfo]
    public var aliases: [ExerciseAlias]
    public var setupNotes: [ExerciseSetupNote]

    private let exercisesByID: [UUID: ExerciseInfo]
    private let searchItems: [SearchItem]

    private struct SearchItem: Equatable, Sendable {
        let candidate: String
        let normalizedCandidate: String
        let exercise: ExerciseInfo
    }

    public init(
        exercises: [ExerciseInfo],
        aliases: [ExerciseAlias] = [],
        setupNotes: [ExerciseSetupNote] = []
    ) {
        self.exercises = exercises
        self.aliases = aliases
        self.setupNotes = setupNotes
        let exercisesByID = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        self.exercisesByID = exercisesByID
        self.searchItems = exercises.map {
            SearchItem(candidate: $0.name, normalizedCandidate: Self.normalized($0.name), exercise: $0)
        } + aliases.compactMap { alias in
            guard let exercise = exercisesByID[alias.exerciseID] else { return nil }
            return SearchItem(candidate: alias.alias, normalizedCandidate: Self.normalized(alias.alias), exercise: exercise)
        }
    }

    public func search(_ query: String, limit: Int = 20) -> [ExerciseSearchResult] {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else {
            return Array(exercises.prefix(limit)).map {
                ExerciseSearchResult(exercise: $0, matchedText: $0.name, score: 0)
            }
        }

        var bestByExerciseID: [UUID: ExerciseSearchResult] = [:]
        for item in searchItems {
            consider(item: item, query: normalizedQuery, into: &bestByExerciseID)
        }

        return bestByExerciseID.values
            .sorted {
                if $0.score == $1.score {
                    $0.exercise.name.localizedStandardCompare($1.exercise.name) == .orderedAscending
                } else {
                    $0.score > $1.score
                }
            }
            .prefix(limit)
            .map { $0 }
    }

    public func analyticsInfo(for exercise: ExerciseInfo) -> ExerciseInfo {
        guard let mappedGlobalID = exercise.mappedGlobalID,
              let global = exercisesByID[mappedGlobalID] else {
            return exercise
        }

        return ExerciseInfo(
            id: exercise.id,
            name: exercise.name,
            movementPattern: exercise.movementPattern ?? global.movementPattern,
            primaryMuscles: exercise.primaryMuscles.isEmpty ? global.primaryMuscles : exercise.primaryMuscles,
            secondaryMuscles: exercise.secondaryMuscles.isEmpty ? global.secondaryMuscles : exercise.secondaryMuscles,
            equipment: exercise.equipment ?? global.equipment,
            isUnilateral: exercise.isUnilateral || global.isUnilateral,
            mappedGlobalID: mappedGlobalID
        )
    }

    public func setupNote(for exerciseID: UUID, userID: UUID) -> ExerciseSetupNote? {
        setupNotes.first { $0.exerciseID == exerciseID && $0.userID == userID }
    }

    private func consider(
        item: SearchItem,
        query: String,
        into bestByExerciseID: inout [UUID: ExerciseSearchResult]
    ) {
        let score = Self.score(candidate: item.normalizedCandidate, query: query)
        guard score > 0 else { return }

        let result = ExerciseSearchResult(exercise: item.exercise, matchedText: item.candidate, score: score)
        if let existing = bestByExerciseID[item.exercise.id] {
            if result.score > existing.score {
                bestByExerciseID[item.exercise.id] = result
            }
        } else {
            bestByExerciseID[item.exercise.id] = result
        }
    }

    private static func score(candidate: String, query: String) -> Int {
        if candidate == query { return 100 }
        if candidate.hasPrefix(query) { return 90 }
        if candidate.contains(query) { return 75 }

        let candidateTokens = candidate.split(separator: " ").map(String.init)
        if candidateTokens.contains(query) { return 72 }
        if candidateTokens.contains(where: { $0.hasPrefix(query) }) { return 68 }

        let threshold = max(1, min(3, query.count / 3))
        if levenshtein(candidate, query) <= threshold { return 62 }
        if candidateTokens.contains(where: { levenshtein($0, query) <= threshold }) { return 58 }

        return 0
    }

    private static func normalized(_ value: String) -> String {
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

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let left = Array(a)
        let right = Array(b)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }

        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let substitutionCost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + substitutionCost
                )
            }
            swap(&previous, &current)
        }

        return previous[right.count]
    }
}

public enum GlobalExerciseLibrary {
    public static let romanianDeadliftID = UUID(uuidString: "00000000-0000-7000-8000-000000000201")!
    public static let bayesianCableCurlID = UUID(uuidString: "00000000-0000-7000-8000-000000000202")!
    public static let overheadCableTricepsExtensionID = UUID(uuidString: "00000000-0000-7000-8000-000000000203")!
    public static let chestSupportedTBarRowID = UUID(uuidString: "00000000-0000-7000-8000-000000000204")!
    public static let smithMachineSquatID = UUID(uuidString: "00000000-0000-7000-8000-000000000205")!
    public static let machineChestPressID = UUID(uuidString: "00000000-0000-7000-8000-000000000206")!
    public static let treadmillRunID = UUID(uuidString: "00000000-0000-7000-8000-000000000207")!
    public static let indoorCycleID = UUID(uuidString: "00000000-0000-7000-8000-000000000208")!
    public static let rowErgID = UUID(uuidString: "00000000-0000-7000-8000-000000000209")!

    public static let rdlAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000301")!
    public static let bayesianCurlAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000302")!
    public static let cableBayesianCurlAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000303")!
    public static let overheadCableTriAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000304")!
    public static let chestSupportedTBarAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000305")!
    public static let smithSquatAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000306")!
    public static let machinePressAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000307")!
    public static let tbarRowAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000308")!
    public static let treadmillAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000309")!
    public static let bikeAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000310")!
    public static let rowerAliasID = UUID(uuidString: "00000000-0000-7000-8000-000000000311")!

    public static let snapshot = ExerciseLibrarySnapshot(
        exercises: [
            ExerciseInfo(
                id: romanianDeadliftID,
                name: "Romanian Deadlift",
                movementPattern: "hinge",
                primaryMuscles: ["hamstrings", "glutes"],
                secondaryMuscles: ["spinal_erectors", "forearms"],
                equipment: "barbell"
            ),
            ExerciseInfo(
                id: bayesianCableCurlID,
                name: "Bayesian Cable Curl",
                movementPattern: "elbow_flexion",
                primaryMuscles: ["biceps"],
                secondaryMuscles: ["forearms"],
                equipment: "cable",
                isUnilateral: true
            ),
            ExerciseInfo(
                id: overheadCableTricepsExtensionID,
                name: "Overhead Cable Triceps Extension",
                movementPattern: "elbow_extension",
                primaryMuscles: ["triceps"],
                secondaryMuscles: ["front_delts"],
                equipment: "cable"
            ),
            ExerciseInfo(
                id: chestSupportedTBarRowID,
                name: "Chest-Supported T-Bar Row",
                movementPattern: "horizontal_pull",
                primaryMuscles: ["lats", "mid_back"],
                secondaryMuscles: ["rear_delts", "biceps"],
                equipment: "machine"
            ),
            ExerciseInfo(
                id: smithMachineSquatID,
                name: "Smith Machine Squat",
                movementPattern: "squat",
                primaryMuscles: ["quads", "glutes"],
                secondaryMuscles: ["adductors"],
                equipment: "smith"
            ),
            ExerciseInfo(
                id: machineChestPressID,
                name: "Machine Chest Press",
                movementPattern: "horizontal_push",
                primaryMuscles: ["chest"],
                secondaryMuscles: ["triceps", "front_delts"],
                equipment: "machine"
            ),
            ExerciseInfo(
                id: treadmillRunID,
                name: "Treadmill Run",
                movementPattern: "cardio",
                primaryMuscles: ["cardiovascular", "quadriceps", "glutes"],
                secondaryMuscles: ["hamstrings", "calves"],
                equipment: "treadmill"
            ),
            ExerciseInfo(
                id: indoorCycleID,
                name: "Indoor Cycle",
                movementPattern: "cardio",
                primaryMuscles: ["cardiovascular", "quadriceps"],
                secondaryMuscles: ["glutes", "calves"],
                equipment: "bike"
            ),
            ExerciseInfo(
                id: rowErgID,
                name: "Row Erg",
                movementPattern: "cardio",
                primaryMuscles: ["cardiovascular", "lats", "quadriceps"],
                secondaryMuscles: ["hamstrings", "biceps", "upper back"],
                equipment: "rower"
            )
        ],
        aliases: [
            ExerciseAlias(id: rdlAliasID, exerciseID: romanianDeadliftID, alias: "RDL"),
            ExerciseAlias(id: bayesianCurlAliasID, exerciseID: bayesianCableCurlID, alias: "Bayesian curl"),
            ExerciseAlias(id: cableBayesianCurlAliasID, exerciseID: bayesianCableCurlID, alias: "Cable Bayesian curl"),
            ExerciseAlias(id: overheadCableTriAliasID, exerciseID: overheadCableTricepsExtensionID, alias: "Overhead cable tri extension"),
            ExerciseAlias(id: chestSupportedTBarAliasID, exerciseID: chestSupportedTBarRowID, alias: "T-bar row chest supported"),
            ExerciseAlias(id: tbarRowAliasID, exerciseID: chestSupportedTBarRowID, alias: "Tbar row"),
            ExerciseAlias(id: smithSquatAliasID, exerciseID: smithMachineSquatID, alias: "Smith squat"),
            ExerciseAlias(id: machinePressAliasID, exerciseID: machineChestPressID, alias: "Machine press"),
            ExerciseAlias(id: treadmillAliasID, exerciseID: treadmillRunID, alias: "Run"),
            ExerciseAlias(id: bikeAliasID, exerciseID: indoorCycleID, alias: "Bike"),
            ExerciseAlias(id: rowerAliasID, exerciseID: rowErgID, alias: "Rower")
        ]
    )
}
