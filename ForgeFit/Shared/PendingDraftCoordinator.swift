import Foundation

/// Screen-owned registry for editor-local drafts that must be materialized
/// before a terminal action evaluates or persists the model graph.
///
/// Children keep high-frequency text in local state and register one bounded
/// commit closure. Finish, minimize, background, and dismissal can therefore
/// commit synchronously without relying on focus/disappearance callback order.
@MainActor
final class PendingDraftCoordinator {
    typealias Commit = @MainActor () -> Void
    typealias Validate = @MainActor () -> Bool

    private var commits: [UUID: Commit] = [:]
    private var validators: [UUID: Validate] = [:]

    func register(
        _ token: UUID,
        commit: @escaping Commit,
        isValid: @escaping Validate = { true }
    ) {
        commits[token] = commit
        validators[token] = isValid
    }

    func unregister(_ token: UUID) {
        commits[token] = nil
        validators[token] = nil
    }

    /// Breaks every child-registration lifetime at the screen boundary. Some
    /// invalid lazy-row drafts intentionally stay registered while off-screen;
    /// without an explicit teardown those closures can retain the editor graph
    /// after navigation has dismissed it.
    func clearAll() {
        commits.removeAll(keepingCapacity: false)
        validators.removeAll(keepingCapacity: false)
    }

    /// Returns false when a registered editor still contains an invalid draft.
    /// Callers that dismiss or persist must stop at that boundary; background
    /// autosave may safely retry after the user repairs the local value.
    @discardableResult
    func commitAll() -> Bool {
        // A commit may trigger view lifecycle work. Snapshot the closures so
        // registry mutation cannot invalidate this traversal.
        for commit in Array(commits.values) {
            commit()
        }
        return Array(validators.values).allSatisfy { $0() }
    }
}
