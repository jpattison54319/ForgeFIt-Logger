import Foundation

/// One owner for a screen's coalesced persistence boundary.
///
/// Lazy rows may request a save, but they never own a task and never flush as
/// they scroll off-screen. The screen flushes at explicit durability
/// boundaries (background, dismissal, minimize, finish).
@MainActor
final class DeferredSaveCoordinator {
    typealias Operation = @MainActor () -> Void

    private let delay: Duration
    private var task: Task<Void, Never>?
    private var pendingOperation: Operation?
    private var isPaused = false

    init(delay: Duration = .seconds(2)) {
        self.delay = delay
    }

    var hasPendingSave: Bool { pendingOperation != nil }

    func schedule(_ operation: @escaping Operation) {
        task?.cancel()
        task = nil
        pendingOperation = operation
        armIfNeeded()
    }

    /// A persistence debounce is still a deadline, not proof of UI idleness.
    /// Scroll surfaces pause their timer while a finger/deceleration is active
    /// so a root-query refresh cannot land in the middle of frame delivery.
    func pause() {
        guard !isPaused else { return }
        isPaused = true
        task?.cancel()
        task = nil
    }

    /// Restarts the full quiet-period delay for a pending change. Nothing is
    /// committed synchronously when scrolling ends.
    func resume() {
        guard isPaused else { return }
        isPaused = false
        armIfNeeded()
    }

    private func armIfNeeded() {
        guard !isPaused, pendingOperation != nil else { return }
        let delay = self.delay
        task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.performPending()
        }
    }

    /// Commits the one coalesced operation. Calling flush while idle is a
    /// no-op, which keeps repeated lifecycle callbacks idempotent.
    func flush() {
        guard pendingOperation != nil else { return }
        task?.cancel()
        task = nil
        performPending()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingOperation = nil
    }

    private func performPending() {
        task?.cancel()
        task = nil
        let operation = pendingOperation
        pendingOperation = nil
        operation?()
    }

    deinit {
        task?.cancel()
    }
}
