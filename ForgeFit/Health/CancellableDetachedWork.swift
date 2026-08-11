import Foundation

/// Runs CPU-heavy, `Sendable` work on a detached executor so it never
/// inherits the caller's actor — in practice the app target's default
/// MainActor, where deep bucketing would stall touch and scroll handling.
///
/// A bare `Task.detached` does NOT inherit the caller's cancellation state,
/// so this utility forwards it: when the surrounding task is cancelled, the
/// child is cancelled too, and a long aggregation (the 730-day readiness
/// path) stops at the next cancellation checkpoint instead of grinding on
/// after the user left the screen or the refresh was superseded. This is the
/// same shape every other worker in the app uses inline
/// (`Task.detached` + `withTaskCancellationHandler`), promoted to one
/// explicit, testable utility.
nonisolated enum CancellableDetachedWork {
    /// Executes `body` on a detached executor, awaiting its result. The
    /// caller's cancellation is forwarded to the child.
    static func run<Output: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ body: @escaping @Sendable () async -> Output
    ) async -> Output {
        let task: Task<Output, Never> = Task.detached(priority: priority) {
            await body()
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
