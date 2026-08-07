import Foundation
import SwiftData

enum BackupExportPolicy {
    static func canStart(
        hasPendingChanges: Bool,
        isLiveWorkoutActive: Bool,
        isBackgrounded: Bool,
        hasExportInFlight: Bool
    ) -> Bool {
        hasPendingChanges && !isLiveWorkoutActive && !isBackgrounded && !hasExportInFlight
    }
}

/// Debounces backup exports so a burst of edits produces one write, and
/// runs a daily catch-up so preference-only changes still reach iCloud
/// within a day. Only LOG-layer changes matter here — routines and the
/// rest of the plan layer sync via CloudKit and aren't in the backup.
@MainActor
final class BackupScheduler {
    static let shared = BackupScheduler()

    private var container: ModelContainer?
    private var debounceTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var hasPendingChanges = false
    private var isLiveWorkoutActive = false
    private var isBackgrounded = false
    private static let debounceSeconds: Double = 60
    private static let foregroundResumeDelay: Duration = .seconds(12)

    func configure(container: ModelContainer) {
        self.container = container
    }

    /// Call after any save that changes workouts/sets/cardio/preferences.
    func noteLogDataChanged() {
        guard container != nil else { return }
        hasPendingChanges = true
        scheduleExport(after: .seconds(Self.debounceSeconds))
    }

    /// A live workout is already durable in SwiftData. Hold the derived iCloud
    /// projection until the logger is gone so its full-history snapshot cannot
    /// steal interaction time from set entry.
    func setLiveWorkoutActive(_ isActive: Bool) {
        isLiveWorkoutActive = isActive
        if isActive {
            debounceTask?.cancel()
            debounceTask = nil
            exportTask?.cancel()
        } else if hasPendingChanges, !isBackgrounded {
            scheduleExport(after: .seconds(2))
        }
    }

    /// Do not begin a full-store projection during the app-switch transition.
    /// Local SwiftData remains the durable source of truth.
    func pauseForBackground() {
        isBackgrounded = true
        debounceTask?.cancel()
        debounceTask = nil
        exportTask?.cancel()
    }

    /// A short post-foreground quiet period keeps backup relationship faulting
    /// away from the first frames the user can touch.
    func resumeAfterForeground() {
        isBackgrounded = false
        if hasPendingChanges, !isLiveWorkoutActive {
            scheduleExport(after: Self.foregroundResumeDelay)
        }
    }

    /// Explicit export (daily catch-up and post-restore) — coalesces with an
    /// existing export and still respects live-workout/background gating.
    func exportNow() {
        guard container != nil else { return }
        hasPendingChanges = true
        scheduleExport(after: .zero)
    }

    /// At most one unprompted export per day (launch path).
    func dailyCheckIfDue() {
        let last = UserDefaults.standard.object(forKey: BackupExporter.lastSuccessKey) as? Date
        guard last.map({ Date().timeIntervalSince($0) > 24 * 3600 }) ?? true else { return }
        hasPendingChanges = true
        scheduleExport(after: Self.foregroundResumeDelay)
    }

    private func scheduleExport(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = nil
        guard BackupExportPolicy.canStart(
            hasPendingChanges: hasPendingChanges,
            isLiveWorkoutActive: isLiveWorkoutActive,
            isBackgrounded: isBackgrounded,
            hasExportInFlight: exportTask != nil
        ) else { return }
        debounceTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            self?.debounceTask = nil
            self?.startExportIfPossible()
        }
    }

    private func startExportIfPossible() {
        guard let container,
              BackupExportPolicy.canStart(
                  hasPendingChanges: hasPendingChanges,
                  isLiveWorkoutActive: isLiveWorkoutActive,
                  isBackgrounded: isBackgrounded,
                  hasExportInFlight: exportTask != nil
              ) else { return }

        hasPendingChanges = false
        exportTask = Task { @MainActor [weak self] in
            let status = await BackupExporter.shared.exportNow(container: container)
            guard let self else { return }
            exportTask = nil
            switch status {
            case .done:
                if hasPendingChanges {
                    scheduleExport(after: .seconds(2))
                }
            case .idle:
                hasPendingChanges = true
                if !isLiveWorkoutActive, !isBackgrounded {
                    scheduleExport(after: Self.foregroundResumeDelay)
                }
            case .unavailable, .failed, .exporting:
                // Retain dirty state for the next app/data trigger, but avoid a
                // retry loop while iCloud is unavailable or persistently failing.
                hasPendingChanges = true
            }
        }
    }
}
