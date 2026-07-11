import Foundation
import SwiftData

/// Debounces backup exports so a burst of edits produces one write, and
/// runs a daily catch-up so preference-only changes still reach iCloud
/// within a day. Only LOG-layer changes matter here — routines and the
/// rest of the plan layer sync via CloudKit and aren't in the backup.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()

    private var container: ModelContainer?
    private var debounceTask: Task<Void, Never>?
    private static let debounceSeconds: Double = 60

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Call after any save that changes workouts/sets/cardio/preferences.
    func noteLogDataChanged() {
        guard container != nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            await self?.exportIfConfigured()
        }
    }

    /// Immediate export (background transition, post-restore) — skips the
    /// debounce but coalesces with one already in flight.
    func exportNow() {
        debounceTask?.cancel()
        Task { [weak self] in
            await self?.exportIfConfigured()
        }
    }

    /// At most one unprompted export per day (launch path).
    func dailyCheckIfDue() {
        let last = UserDefaults.standard.object(forKey: BackupExporter.lastSuccessKey) as? Date
        guard last.map({ Date().timeIntervalSince($0) > 24 * 3600 }) ?? true else { return }
        exportNow()
    }

    private func exportIfConfigured() async {
        guard let container else { return }
        await BackupExporter.shared.exportNow(container: container)
    }
}
