import Foundation

enum AcceptanceOutcome: String, Codable, Sendable {
    case pass
    case fail
    case suspect
    case blocked
    case unverified
}

enum AcceptanceCheckpointPhase: String, Codable, Sendable {
    case setup
    case transition
    case assertion
}

struct AcceptanceFailureEvidence: Codable, Sendable {
    let phase: AcceptanceCheckpointPhase
    let message: String
    let checkpointID: String?
    let sourceFile: String
    let sourceLine: UInt
}

struct AcceptanceOracleResult: Codable, Sendable {
    let id: String
    let outcome: AcceptanceOutcome
    let message: String
}

/// A typed, deterministic check that runs after the user action. The result
/// is persisted beside the visual evidence so an AI reviewer never has to
/// infer a persistence or arithmetic invariant from a screenshot alone.
struct AcceptanceOracle {
    let id: String
    let evaluate: () -> AcceptanceOracleResult

    init(id: String, evaluate: @escaping () -> AcceptanceOracleResult) {
        self.id = id
        self.evaluate = evaluate
    }
}

struct AcceptanceRunManifest: Codable, Sendable {
    let schemaVersion: Int
    let runID: String
    let startedAt: Date
    let finishedAt: Date
    let scenario: AcceptanceScenario
    let environment: AcceptanceEnvironment
    let outcome: AcceptanceOutcome
    let checkpointCount: Int
    let failedCheckpointCount: Int
    let artifactFiles: [String]
    let failures: [AcceptanceFailureEvidence]
    let unverifiedCheckpointCount: Int
    let declaredButUnusedCount: Int
    let rubricID: String
    let rubricVersion: Int

    init(
        schemaVersion: Int,
        runID: String,
        startedAt: Date,
        finishedAt: Date,
        scenario: AcceptanceScenario,
        environment: AcceptanceEnvironment,
        outcome: AcceptanceOutcome,
        checkpointCount: Int,
        failedCheckpointCount: Int,
        artifactFiles: [String],
        failures: [AcceptanceFailureEvidence] = [],
        unverifiedCheckpointCount: Int = 0,
        declaredButUnusedCount: Int = 0,
        rubricID: String = "forgefit-ai-acceptance",
        rubricVersion: Int = 3
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.scenario = scenario
        self.environment = environment
        self.outcome = outcome
        self.checkpointCount = checkpointCount
        self.failedCheckpointCount = failedCheckpointCount
        self.artifactFiles = artifactFiles
        self.failures = failures
        self.unverifiedCheckpointCount = unverifiedCheckpointCount
        self.declaredButUnusedCount = declaredButUnusedCount
        self.rubricID = rubricID
        self.rubricVersion = rubricVersion
    }
}

struct AcceptanceEnvironment: Codable, Sendable {
    let platform: String
    let device: String
    let operatingSystem: String
    let locale: String
    let timeZone: String
    let appearance: String
    let dynamicType: String
    let gitCommit: String?
    let gitDirty: Bool
    let commitUnknown: Bool

    init(
        platform: String,
        device: String,
        operatingSystem: String,
        locale: String,
        timeZone: String,
        appearance: String,
        dynamicType: String,
        gitCommit: String?,
        gitDirty: Bool = false,
        commitUnknown: Bool? = nil
    ) {
        self.platform = platform
        self.device = device
        self.operatingSystem = operatingSystem
        self.locale = locale
        self.timeZone = timeZone
        self.appearance = appearance
        self.dynamicType = dynamicType
        self.gitCommit = gitCommit
        self.gitDirty = gitDirty
        self.commitUnknown = commitUnknown ?? (gitCommit == nil)
    }
}

struct AcceptanceCheckpoint: Codable, Sendable {
    let id: String
    let title: String
    let action: String
    let expectedVisibleIdentifiers: [String]
    let expectedVisibleLabels: [String]
    let screenshotRequired: Bool
    let phase: AcceptanceCheckpointPhase
    let invariants: [String]

    init(
        id: String,
        title: String,
        action: String,
        expectedVisibleIdentifiers: [String],
        expectedVisibleLabels: [String],
        screenshotRequired: Bool,
        phase: AcceptanceCheckpointPhase = .assertion,
        invariants: [String] = []
    ) {
        self.id = id
        self.title = title
        self.action = action
        self.expectedVisibleIdentifiers = expectedVisibleIdentifiers
        self.expectedVisibleLabels = expectedVisibleLabels
        self.screenshotRequired = screenshotRequired
        self.phase = phase
        self.invariants = invariants
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case action
        case expectedVisibleIdentifiers
        case expectedVisibleLabels
        case screenshotRequired
        case phase
        case invariants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        action = try container.decode(String.self, forKey: .action)
        expectedVisibleIdentifiers = try container.decode([String].self, forKey: .expectedVisibleIdentifiers)
        expectedVisibleLabels = try container.decode([String].self, forKey: .expectedVisibleLabels)
        screenshotRequired = try container.decode(Bool.self, forKey: .screenshotRequired)
        phase = try container.decodeIfPresent(AcceptanceCheckpointPhase.self, forKey: .phase) ?? .assertion
        invariants = try container.decodeIfPresent([String].self, forKey: .invariants) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(action, forKey: .action)
        try container.encode(expectedVisibleIdentifiers, forKey: .expectedVisibleIdentifiers)
        try container.encode(expectedVisibleLabels, forKey: .expectedVisibleLabels)
        try container.encode(screenshotRequired, forKey: .screenshotRequired)
        try container.encode(phase, forKey: .phase)
        try container.encode(invariants, forKey: .invariants)
    }
}

struct AcceptanceCheckpointEvidence: Codable, Sendable {
    let scenarioID: String
    let checkpoint: AcceptanceCheckpoint
    let outcome: AcceptanceOutcome
    let startedAt: Date
    let finishedAt: Date
    let observedIdentifiers: [String]
    let observedLabels: [String]
    let missingIdentifiers: [String]
    let missingLabels: [String]
    let screenshotFile: String?
    let accessibilityTreeFile: String?
    let notes: [String]
    let beforeScreenshotFile: String?
    let beforeAccessibilityTreeFile: String?
    let oracleResults: [AcceptanceOracleResult]

    init(
        scenarioID: String,
        checkpoint: AcceptanceCheckpoint,
        outcome: AcceptanceOutcome,
        startedAt: Date,
        finishedAt: Date,
        observedIdentifiers: [String],
        observedLabels: [String],
        missingIdentifiers: [String],
        missingLabels: [String],
        screenshotFile: String?,
        accessibilityTreeFile: String?,
        notes: [String],
        beforeScreenshotFile: String? = nil,
        beforeAccessibilityTreeFile: String? = nil,
        oracleResults: [AcceptanceOracleResult] = []
    ) {
        self.scenarioID = scenarioID
        self.checkpoint = checkpoint
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.observedIdentifiers = observedIdentifiers
        self.observedLabels = observedLabels
        self.missingIdentifiers = missingIdentifiers
        self.missingLabels = missingLabels
        self.screenshotFile = screenshotFile
        self.accessibilityTreeFile = accessibilityTreeFile
        self.notes = notes
        self.beforeScreenshotFile = beforeScreenshotFile
        self.beforeAccessibilityTreeFile = beforeAccessibilityTreeFile
        self.oracleResults = oracleResults
    }
}

struct AcceptanceJudgeRequest: Codable, Sendable {
    let schemaVersion: Int
    let scenario: AcceptanceScenario
    let environment: AcceptanceEnvironment
    let checkpointEvidence: [AcceptanceCheckpointEvidence]
    let judgeInstructions: String
    let responseSchema: AcceptanceJudgeResponseSchema
    let rubricID: String
    let rubricVersion: Int
    let failures: [AcceptanceFailureEvidence]

    init(
        schemaVersion: Int,
        scenario: AcceptanceScenario,
        environment: AcceptanceEnvironment,
        checkpointEvidence: [AcceptanceCheckpointEvidence],
        judgeInstructions: String,
        responseSchema: AcceptanceJudgeResponseSchema,
        rubricID: String = "forgefit-ai-acceptance",
        rubricVersion: Int = 3,
        failures: [AcceptanceFailureEvidence] = []
    ) {
        self.schemaVersion = schemaVersion
        self.scenario = scenario
        self.environment = environment
        self.checkpointEvidence = checkpointEvidence
        self.judgeInstructions = judgeInstructions
        self.responseSchema = responseSchema
        self.rubricID = rubricID
        self.rubricVersion = rubricVersion
        self.failures = failures
    }
}

struct AcceptanceJudgeResponseSchema: Codable, Sendable {
    let outcome: String
    let findings: [AcceptanceJudgeFinding]
}

struct AcceptanceJudgeFinding: Codable, Sendable {
    let severity: String
    let category: String
    let observation: String
    let expected: String
    let actual: String
    let confidence: Double
    let checkpointID: String
    let evidencePaths: [String]
}
