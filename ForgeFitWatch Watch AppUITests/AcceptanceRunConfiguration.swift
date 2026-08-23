import Foundation

/// Reads acceptance-run settings from the test process or the stable marker
/// used when xcodebuild does not forward arbitrary environment variables.
enum AcceptanceRunConfiguration {
    static let defaultMarkerPath = "/tmp/forgefit-acceptance/.capture-actions"

    static var actionCaptureEnabled: Bool {
        ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ACTIONS"] == "1"
            || FileManager.default.fileExists(atPath: markerPath)
    }

    static var artifactRoot: URL {
        URL(fileURLWithPath: value(for: "FORGEFIT_ACCEPTANCE_ARTIFACTS") ?? "/tmp/forgefit-acceptance", isDirectory: true)
    }

    static var gitCommit: String? {
        value(for: "GIT_COMMIT")
    }

    static var gitDirty: Bool {
        value(for: "GIT_DIRTY") == "1"
    }

    static var rubricID: String {
        value(for: "FORGEFIT_ACCEPTANCE_RUBRIC_ID") ?? "forgefit-ai-acceptance"
    }

    static var rubricVersion: Int {
        Int(value(for: "FORGEFIT_ACCEPTANCE_RUBRIC_VERSION") ?? "1") ?? 1
    }

    static var markerPath: String {
        ProcessInfo.processInfo.environment["FORGEFIT_ACCEPTANCE_ACTION_MARKER"] ?? defaultMarkerPath
    }

    private static func value(for key: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[key], !environmentValue.isEmpty {
            return environmentValue
        }

        guard let contents = try? String(contentsOfFile: markerPath, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[0]) == key else { continue }
            return String(parts[1])
        }
        return nil
    }
}
