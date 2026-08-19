import Foundation
import Observation
import SwiftData

/// Automatic workout-history backup is a product contract, not an
/// experimental switch. The emitted file remains deliberately sanitized:
/// routines sync through private CloudKit, while the local workout log is
/// copied to iCloud Drive without Apple Health-derived fields.
enum BackupAutomationPolicy {
    static let isEnabledInThisRelease = true
}

nonisolated enum WorkoutHistoryBackupState: Equatable, Sendable {
    case waitingForFirstBackup
    case pending
    case exporting
    case upToDate
    case unavailable
    case failed(String)
    case deleting

    var isBusy: Bool {
        self == .exporting || self == .deleting
    }
}

/// Production uses `BackupExporter.shared`; the seam keeps automatic retry,
/// failure visibility, and deletion behavior deterministic in tests.
nonisolated protocol BackupManaging: BackupDeleting {
    func exportNow(container: ModelContainer) async -> BackupExporter.Status
}

enum BackupExportPolicy {
    static func canStart(
        hasPendingChanges: Bool,
        isLiveWorkoutActive: Bool,
        isBackgrounded: Bool,
        hasExportInFlight: Bool,
        hasDeletionInFlight: Bool = false
    ) -> Bool {
        hasPendingChanges
            && !isLiveWorkoutActive
            && !isBackgrounded
            && !hasExportInFlight
            && !hasDeletionInFlight
    }
}

/// Debounces backup exports so a burst of edits produces one write, and
/// runs a daily catch-up so preference-only changes still reach iCloud
/// within a day while the app is used. Only LOG-layer changes matter here —
/// routines and the rest of the plan layer sync through private CloudKit.
@MainActor
@Observable
final class BackupScheduler {
    static let shared = BackupScheduler()

    static let lastFailureMessageKey = "backupLastFailureMessage"
    static let lastFailureAtKey = "backupLastFailureAt"

    private(set) var state: WorkoutHistoryBackupState
    private(set) var lastSuccessAt: Date?

    @ObservationIgnored private let manager: any BackupManaging
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let debounceDelay: Duration
    @ObservationIgnored private let foregroundResumeDelay: Duration
    @ObservationIgnored private let postWorkoutDelay: Duration
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var hasPendingChanges = false
    @ObservationIgnored private var isLiveWorkoutActive = false
    @ObservationIgnored private var isBackgrounded = false
    @ObservationIgnored private var isDeletionInFlight = false
    @ObservationIgnored private var operationGeneration = 0

    init(
        manager: any BackupManaging = BackupExporter.shared,
        defaults: UserDefaults = .standard,
        debounceDelay: Duration = .seconds(60),
        foregroundResumeDelay: Duration = .seconds(12),
        postWorkoutDelay: Duration = .seconds(2)
    ) {
        self.manager = manager
        self.defaults = defaults
        self.debounceDelay = debounceDelay
        self.foregroundResumeDelay = foregroundResumeDelay
        self.postWorkoutDelay = postWorkoutDelay

        let lastSuccess = defaults.object(forKey: BackupExporter.lastSuccessKey) as? Date
        let lastFailure = defaults.string(forKey: Self.lastFailureMessageKey)
        let lastFailureAt = defaults.object(forKey: Self.lastFailureAtKey) as? Date
        lastSuccessAt = lastSuccess
        if let lastFailure,
           let lastFailureAt,
           lastSuccess.map({ lastFailureAt >= $0 }) ?? true {
            state = .failed(lastFailure)
        } else {
            state = lastSuccess == nil ? .waitingForFirstBackup : .upToDate
        }
    }

    func configure(container: ModelContainer) {
        guard BackupAutomationPolicy.isEnabledInThisRelease else {
            self.container = nil
            debounceTask?.cancel()
            exportTask?.cancel()
            debounceTask = nil
            exportTask = nil
            hasPendingChanges = false
            return
        }
        self.container = container
    }

    /// Call after any save that changes workouts, sets, cardio, microcycle
    /// tracking, rest markers, or backed-up preferences.
    func noteLogDataChanged() {
        guard BackupAutomationPolicy.isEnabledInThisRelease, container != nil else { return }
        hasPendingChanges = true
        if !state.isBusy, !isFailureState {
            state = .pending
        }
        scheduleExport(after: debounceDelay)
    }

    /// A live workout is already durable in SwiftData. Hold the derived iCloud
    /// projection until the logger is gone so full-history relationship
    /// faulting cannot steal interaction time from set entry.
    func setLiveWorkoutActive(_ isActive: Bool) {
        guard BackupAutomationPolicy.isEnabledInThisRelease else { return }
        isLiveWorkoutActive = isActive
        if isActive {
            debounceTask?.cancel()
            debounceTask = nil
            exportTask?.cancel()
        } else if hasPendingChanges, !isBackgrounded {
            scheduleExport(after: postWorkoutDelay)
        }
    }

    /// Do not begin a full-store projection during the app-switch transition.
    /// Local SwiftData remains the durable source of truth.
    func pauseForBackground() {
        guard BackupAutomationPolicy.isEnabledInThisRelease else { return }
        isBackgrounded = true
        debounceTask?.cancel()
        debounceTask = nil
        exportTask?.cancel()
    }

    /// A short post-foreground quiet period keeps backup relationship faulting
    /// away from the first frames the user can touch.
    func resumeAfterForeground() {
        guard BackupAutomationPolicy.isEnabledInThisRelease else { return }
        isBackgrounded = false
        if hasPendingChanges, !isLiveWorkoutActive {
            scheduleExport(after: foregroundResumeDelay)
        }
    }

    /// User-visible retry / "Back up now". It coalesces with any scheduled
    /// export and still respects live-workout and background gating.
    func exportNow() {
        guard BackupAutomationPolicy.isEnabledInThisRelease, container != nil else { return }
        hasPendingChanges = true
        if !state.isBusy { state = .pending }
        scheduleExport(after: .zero)
    }

    /// At most one unprompted catch-up per day (launch path). A missing stamp
    /// means a fresh install and therefore schedules the first backup.
    func dailyCheckIfDue(now: Date = Date()) {
        guard BackupAutomationPolicy.isEnabledInThisRelease else { return }
        guard lastSuccessAt.map({ now.timeIntervalSince($0) > 24 * 3600 }) ?? true else { return }
        hasPendingChanges = true
        if !state.isBusy, !isFailureState { state = .pending }
        scheduleExport(after: foregroundResumeDelay)
    }

    /// Deletes the two rotating workout-history files without deleting local
    /// workouts or the CloudKit-synced training plan. Because automatic backup
    /// is always on, a later log change can create a fresh backup again.
    @discardableResult
    func deleteBackup() async -> BackupDeletionResult {
        guard !isDeletionInFlight else {
            return .failed("Backup deletion is already in progress.")
        }

        isDeletionInFlight = true
        operationGeneration += 1
        debounceTask?.cancel()
        debounceTask = nil
        let inFlight = exportTask
        exportTask = nil
        inFlight?.cancel()
        // A prior failed/pending export must not recreate the files moments
        // after an explicit delete. A genuinely new save that arrives while
        // deletion is in flight will set this back to true and be preserved.
        hasPendingChanges = false
        state = .deleting
        if let inFlight { await inFlight.value }

        let result = await manager.deleteAllBackups()
        isDeletionInFlight = false
        switch result {
        case .deleted:
            lastSuccessAt = nil
            defaults.removeObject(forKey: BackupExporter.lastSuccessKey)
            clearFailure()
            state = hasPendingChanges ? .pending : .waitingForFirstBackup
        case .unavailable:
            recordFailure("iCloud Drive is unavailable. Sign in to iCloud, turn on iCloud Drive, then try again.")
            state = .unavailable
        case .cancelled:
            let message = "Backup deletion was interrupted."
            recordFailure(message)
            state = .failed(message)
        case .failed(let message):
            recordFailure(message)
            state = .failed(message)
        }

        if hasPendingChanges, !isLiveWorkoutActive, !isBackgrounded {
            scheduleExport(after: foregroundResumeDelay)
        }
        return result
    }

    private var isFailureState: Bool {
        switch state {
        case .failed, .unavailable: true
        default: false
        }
    }

    private func scheduleExport(after delay: Duration) {
        debounceTask?.cancel()
        debounceTask = nil
        guard BackupExportPolicy.canStart(
            hasPendingChanges: hasPendingChanges,
            isLiveWorkoutActive: isLiveWorkoutActive,
            isBackgrounded: isBackgrounded,
            hasExportInFlight: exportTask != nil,
            hasDeletionInFlight: isDeletionInFlight
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
                  hasExportInFlight: exportTask != nil,
                  hasDeletionInFlight: isDeletionInFlight
              ) else { return }

        hasPendingChanges = false
        let priorState = state
        state = .exporting
        operationGeneration += 1
        let generation = operationGeneration
        let manager = manager
        exportTask = Task { @MainActor [weak self] in
            let outcome = await manager.exportNow(container: container)
            guard let self, generation == operationGeneration else { return }
            exportTask = nil
            handleExportOutcome(outcome, priorState: priorState)
        }
    }

    private func handleExportOutcome(
        _ outcome: BackupExporter.Status,
        priorState: WorkoutHistoryBackupState
    ) {
        switch outcome {
        case .done(let stamp):
            lastSuccessAt = stamp
            defaults.set(stamp, forKey: BackupExporter.lastSuccessKey)
            clearFailure()
            if hasPendingChanges {
                state = .pending
                scheduleExport(after: postWorkoutDelay)
            } else {
                state = .upToDate
            }
        case .idle:
            hasPendingChanges = true
            state = priorState == .exporting ? .pending : priorState
            if !isLiveWorkoutActive, !isBackgrounded {
                scheduleExport(after: foregroundResumeDelay)
            }
        case .unavailable:
            hasPendingChanges = true
            recordFailure("iCloud Drive is unavailable. Sign in to iCloud, turn on iCloud Drive, then try again.")
            state = .unavailable
        case .failed(let message):
            hasPendingChanges = true
            recordFailure(message)
            state = .failed(message)
        case .exporting:
            // A completed `exportNow` call should never return this transient
            // actor state. Preserve dirty work and expose a retryable failure
            // instead of falsely claiming success.
            let message = "The backup did not finish. Try again."
            hasPendingChanges = true
            recordFailure(message)
            state = .failed(message)
        }
    }

    private func recordFailure(_ message: String) {
        defaults.set(message, forKey: Self.lastFailureMessageKey)
        defaults.set(Date(), forKey: Self.lastFailureAtKey)
    }

    private func clearFailure() {
        defaults.removeObject(forKey: Self.lastFailureMessageKey)
        defaults.removeObject(forKey: Self.lastFailureAtKey)
    }

    #if DEBUG
    /// Lets unit tests await a zero-delay scheduled export without polling.
    func waitForScheduledOperationForTesting() async {
        if let debounceTask { await debounceTask.value }
        if let exportTask { await exportTask.value }
    }
    #endif
}
