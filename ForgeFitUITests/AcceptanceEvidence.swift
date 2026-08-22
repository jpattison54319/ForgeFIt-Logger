import Foundation

enum AcceptanceOutcome: String, Codable, Sendable {
    case pass
    case fail
    case suspect
    case blocked
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
}

struct AcceptanceJudgeRequest: Codable, Sendable {
    let schemaVersion: Int
    let scenario: AcceptanceScenario
    let checkpointEvidence: [AcceptanceCheckpointEvidence]
    let judgeInstructions: String
    let responseSchema: AcceptanceJudgeResponseSchema
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
