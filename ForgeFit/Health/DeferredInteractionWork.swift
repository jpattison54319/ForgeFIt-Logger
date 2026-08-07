import Foundation

/// Coalesces interaction-triggered external work without ever running it in
/// the input event's run-loop turn. Lifecycle and terminal events can flush
/// the latest pending work synchronously through `flush()`.
@MainActor
final class DeferredInteractionWork {
    private let delay: Duration
    private var task: Task<Void, Never>?
    private var pendingWork: (() -> Void)?

    init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    var hasPendingWork: Bool {
        pendingWork != nil
    }

    func schedule(_ work: @escaping () -> Void) {
        pendingWork = work
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            runPendingWork()
        }
    }

    func flush() {
        task?.cancel()
        runPendingWork()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingWork = nil
    }

    private func runPendingWork() {
        task = nil
        let work = pendingWork
        pendingWork = nil
        work?()
    }
}
