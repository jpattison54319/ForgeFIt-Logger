import Foundation

/// Complete presentation state for the optional post-workout routine update.
/// Keeping the copy inputs together prevents a sheet from appearing with a
/// stale routine name or change summary.
struct RoutineUpdatePrompt: Identifiable {
    let id = UUID()
    let routineName: String?
    let changeSummary: String

    var routineReference: String {
        guard let routineName, !routineName.isEmpty else { return "your saved routine" }
        return "“\(routineName)”"
    }
}
