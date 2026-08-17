import ForgeData
import Foundation
import Network
import SwiftData

/// The one pipeline that keeps every cloud surface converged with the local
/// training log. Local SwiftData is the source of truth; the cloud follows:
///
///     save → change feed → route → durable outbox → drain
///                                     ↑ backstop: reconcile (anti-entropy)
///
/// - **Change feed**: one observer on `ModelContext.didSave` sees every save
///   from every context, so a new edit surface can never forget to "also
///   sync" — the coordinator derives the work from what actually changed.
///   (This replaces per-call-site wiring: publish-on-finish callbacks,
///   deleted-workout notifications, scattered backup pokes.)
/// - **Routing**: changed log rows resolve to their owning workout, which
///   maps to an intent — deleted → unpublish, completed & ForgeFit-logged →
///   publish (an edit is just a republish; upserts are keyed by id). The
///   sanitized iCloud backup is a derived artifact of the same change set,
///   so the feed also feeds `BackupScheduler`.
/// - **Durable outbox** (`SocialService.shareOutbox`): intents persist, so
///   offline work executes when connectivity returns instead of being lost.
/// - **Drain triggers**: a short debounce after each change burst, app
///   foreground, and the network path becoming satisfied (`NWPathMonitor`).
/// - **Anti-entropy**: `SocialService.reconcileSharedWorkouts` diffs local
///   stamps against the full remote picture on launch/opt-in (forced) and
///   foreground (throttled), catching anything the event path ever missed.
///
/// The plan store (routines/folders) is deliberately absent here: it syncs
/// via SwiftData+CloudKit `.automatic`, which is already this same shape
/// (change tracking + queued upload + retry) provided by the platform.
@MainActor
final class SyncCoordinator {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    private struct SyncOperation {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Log-store entities whose changes mean training data moved (backup +
    /// social both key off this set). Analytics caches, insights, plan rows,
    /// and exercise-library edits deliberately don't wake the pipeline.
    private static let logEntities: Set<String> = [
        "WorkoutModel", "WorkoutBlockModel", "WorkoutExerciseModel", "SetModel",
        "WorkoutImportBatchModel", "CardioSessionModel", "CardioSplitModel",
        "CardioRoutePointModel", "MicrocycleTrackingModel",
        "MicrocycleWindowModel", "RestDayModel"
    ]

    private let social: SocialService
    private let context: ModelContext
    private let debounce: Duration
    private let postWorkoutDelay: Duration
    private let saveContext: SaveOperation
    private var saveObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var connectivityMonitoringRequested = false
    /// Workout ids touched since the last flush, and the flush task itself —
    /// a burst of saves (logging a set every few seconds) coalesces into one
    /// routing pass.
    private var pendingWorkoutIDs: Set<UUID> = []
    private var flushTask: Task<Void, Never>?
    private var syncOperation: SyncOperation?
    private var cancelledSyncTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var isLiveWorkoutActive = false
    private var needsFullSyncAfterWorkout = false
    /// Ids whose `updatedAt` the last flush stamped itself: the stamp's own
    /// save echoes through the change feed and must not re-trigger routing.
    private var suppressEcho: Set<UUID> = []

    init(
        social: SocialService,
        container: ModelContainer,
        debounce: Duration = .seconds(2),
        postWorkoutDelay: Duration = .seconds(2),
        saveContext: @escaping SaveOperation = { try $0.save() }
    ) {
        self.social = social
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
        self.debounce = debounce
        self.postWorkoutDelay = postWorkoutDelay
        self.saveContext = saveContext
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        pathMonitor?.cancel()
        flushTask?.cancel()
        syncOperation?.task.cancel()
        cancelledSyncTask?.cancel()
        resumeTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Begins observing saves and (optionally) connectivity. Idempotent.
    /// `monitorConnectivity: false` keeps tests deterministic — the path
    /// monitor fires a sync the moment it starts on any online machine.
    func start(monitorConnectivity: Bool = true) {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated { self?.ingest(notification) }
        }

        guard monitorConnectivity else { return }
        connectivityMonitoringRequested = true
        startConnectivityMonitorIfAllowed()
    }

    private func startConnectivityMonitorIfAllowed() {
        guard connectivityMonitoringRequested,
              !isLiveWorkoutActive,
              pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // Connectivity is back — flush what offline queued up.
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Saves remain durable locally during a workout, but relationship walks
    /// and network reconciliation wait until the logger releases priority.
    /// Any number of suppressed events becomes one post-workout full converge.
    func setLiveWorkoutActive(_ isActive: Bool) {
        guard isLiveWorkoutActive != isActive else { return }
        isLiveWorkoutActive = isActive
        if isActive {
            if !pendingWorkoutIDs.isEmpty || syncOperation != nil {
                needsFullSyncAfterWorkout = true
            }
            flushTask?.cancel()
            flushTask = nil
            if let task = syncOperation?.task {
                cancelledSyncTask = task
                task.cancel()
            }
            syncOperation = nil
            resumeTask?.cancel()
            resumeTask = nil
            pathMonitor?.cancel()
            pathMonitor = nil
        } else if needsFullSyncAfterWorkout || !pendingWorkoutIDs.isEmpty {
            schedulePostWorkoutCatchUp()
        }
        if !isActive {
            startConnectivityMonitorIfAllowed()
        }
    }

    /// Foreground / launch / opt-in entry point: drain the outbox, then run
    /// the converge pass (throttled unless forced).
    func syncNow(force: Bool = false) async {
        guard !isLiveWorkoutActive else {
            needsFullSyncAfterWorkout = true
            return
        }
        guard social.isOptedIn else { return }
        if let syncOperation {
            await syncOperation.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await performSync(force: force)
        }
        syncOperation = SyncOperation(id: id, task: task)
        await withTaskCancellationHandler(
            operation: { await task.value },
            onCancel: { task.cancel() }
        )
        if syncOperation?.id == id {
            syncOperation = nil
        }
    }

    private func performSync(force: Bool) async {
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            needsFullSyncAfterWorkout = true
            return
        }
        await social.drainShareOutbox { [weak self] ids in self?.makeItems(for: ids) ?? [] }
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            needsFullSyncAfterWorkout = true
            return
        }
        await social.reconcileSharedWorkouts(
            eligible: eligibleStamps(),
            deletedIDs: deletedWorkoutIDs(),
            force: force
        ) { [weak self] ids in self?.makeItems(for: ids) ?? [] }
        if !Task.isCancelled, !isLiveWorkoutActive {
            needsFullSyncAfterWorkout = false
        }
    }

    // MARK: - Change feed

    private func ingest(_ notification: Notification) {
        // Only saves against OUR container: identifiers from another store
        // (parallel test containers; any future auxiliary container) can't
        // be resolved in this context.
        guard let saving = notification.object as? ModelContext,
              saving.container === context.container else { return }
        // Deleted identifiers count for the backup but are never resolved:
        // their backing data is gone (reading an invalidated model traps),
        // and every user-facing workout delete is a soft delete that arrives
        // as an update. Hard deletes are the automation/reset paths, where
        // the community is deliberately left alone.
        let liveChanges = identifiers(in: notification, keys: [
            ModelContext.NotificationKey.insertedIdentifiers,
            ModelContext.NotificationKey.updatedIdentifiers
        ]).filter { Self.logEntities.contains($0.entityName) }
        let deletions = identifiers(in: notification, keys: [ModelContext.NotificationKey.deletedIdentifiers])
            .contains { Self.logEntities.contains($0.entityName) }
        guard !liveChanges.isEmpty || deletions else { return }

        // Backup is a derived artifact of any log change; its scheduler owns
        // its own debounce.
        BackupScheduler.shared.noteLogDataChanged()

        guard social.isOptedIn else { return }
        guard !isLiveWorkoutActive else {
            needsFullSyncAfterWorkout = true
            return
        }
        var touched = Set<UUID>()
        var sawNonEcho = false
        for identifier in liveChanges {
            guard let workoutID = owningWorkoutID(of: identifier) else { continue }
            if identifier.entityName == "WorkoutModel", suppressEcho.remove(workoutID) != nil {
                continue
            }
            sawNonEcho = true
            touched.insert(workoutID)
        }
        guard sawNonEcho, !touched.isEmpty else { return }

        pendingWorkoutIDs.formUnion(touched)
        scheduleFlush()
    }

    private func identifiers(in notification: Notification, keys: [ModelContext.NotificationKey]) -> [PersistentIdentifier] {
        keys.flatMap { notification.userInfo?[$0.rawValue] as? [PersistentIdentifier] ?? [] }
    }

    /// Child rows resolve up their relationship chain; hard-deleted rows
    /// can't (their fields are gone) and resolve nil. That's acceptable:
    /// every user-facing delete is a soft delete (`deletedAt`), which
    /// arrives as an *update* — and reconcile's evidence rule needs the row
    /// to exist anyway.
    private func owningWorkoutID(of identifier: PersistentIdentifier) -> UUID? {
        switch identifier.entityName {
        case "WorkoutModel":
            return (model(identifier) as WorkoutModel?)?.id
        case "WorkoutBlockModel":
            return (model(identifier) as WorkoutBlockModel?)?.workout?.id
        case "WorkoutExerciseModel":
            return (model(identifier) as WorkoutExerciseModel?)?.workout?.id
        case "SetModel":
            return (model(identifier) as SetModel?)?.workoutExercise?.workout?.id
        case "CardioSessionModel":
            return (model(identifier) as CardioSessionModel?)?.workout?.id
        case "CardioSplitModel":
            return (model(identifier) as CardioSplitModel?)?.cardioSession?.workout?.id
        case "CardioRoutePointModel":
            return (model(identifier) as CardioRoutePointModel?)?.cardioSession?.workout?.id
        default:
            return nil
        }
    }

    private func model<T: PersistentModel>(_ identifier: PersistentIdentifier) -> T? {
        context.model(for: identifier) as? T
    }

    // MARK: - Routing

    private func scheduleFlush() {
        guard !isLiveWorkoutActive else {
            needsFullSyncAfterWorkout = true
            return
        }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        guard !isLiveWorkoutActive, !Task.isCancelled else {
            needsFullSyncAfterWorkout = true
            return
        }
        let ids = pendingWorkoutIDs
        pendingWorkoutIDs = []
        guard !ids.isEmpty, social.isOptedIn else { return }

        var ops: [UUID: SocialService.ShareOp] = [:]
        var publishIDs = Set<UUID>()
        for id in ids {
            guard !Task.isCancelled, !isLiveWorkoutActive else {
                pendingWorkoutIDs.formUnion(ids)
                needsFullSyncAfterWorkout = true
                return
            }
            guard let workout = workout(id) else { continue }   // hard-deleted
            if workout.deletedAt != nil {
                ops[id] = .unpublish
            } else if workout.endedAt != nil, !workout.isImportedHistory {
                // The feed saw content change beneath this workout: advance
                // its clock so the share watermark (and reconcile drift
                // detection on other passes) reflect the edit.
                publishIDs.insert(id)
                ops[id] = .publish
            }
            // In-progress and imported workouts don't touch the community.
        }
        guard !Task.isCancelled, !isLiveWorkoutActive else {
            pendingWorkoutIDs.formUnion(ids)
            needsFullSyncAfterWorkout = true
            return
        }
        if !publishIDs.isEmpty {
            let transaction = ModelContext(context.container)
            transaction.autosaveEnabled = false
            let publishIDList = Array(publishIDs)
            let publishWorkouts = (try? transaction.fetch(FetchDescriptor<WorkoutModel>(
                predicate: #Predicate { publishIDList.contains($0.id) }
            ))) ?? []
            guard publishWorkouts.count == publishIDs.count else {
                pendingWorkoutIDs.formUnion(ids)
                return
            }
            let now = Date()
            publishWorkouts.forEach { workout in
                // Device clocks and restored/imported rows can be ahead of
                // wall time. The share watermark still has to advance for an
                // edit or reconciliation can mistake the new payload for an
                // already-published version.
                workout.updatedAt = max(
                    now,
                    workout.updatedAt.addingTimeInterval(0.001)
                )
            }
            suppressEcho.formUnion(publishIDs)
            do {
                try saveContext(transaction)
            } catch {
                suppressEcho.subtract(publishIDs)
                pendingWorkoutIDs.formUnion(ids)
                return
            }
            // Refresh the coordinator's read context before building the
            // payload so the just-committed watermark is what gets published.
            publishIDs.forEach { _ = workout($0) }
        }

        social.enqueueShare(ops)
        await social.drainShareOutbox { [weak self] ids in self?.makeItems(for: ids) ?? [] }
    }

    /// Nudges the pending flush to run now (workout finish taps this so the
    /// share appears immediately instead of after the debounce).
    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        guard !isLiveWorkoutActive else {
            needsFullSyncAfterWorkout = true
            return
        }
        await flush()
    }

    private func schedulePostWorkoutCatchUp() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self, postWorkoutDelay] in
            if postWorkoutDelay > .zero {
                try? await Task.sleep(for: postWorkoutDelay)
            }
            guard let self, !Task.isCancelled, !isLiveWorkoutActive else { return }
            if let cancelledSyncTask {
                await cancelledSyncTask.value
                self.cancelledSyncTask = nil
            }
            guard !Task.isCancelled, !isLiveWorkoutActive else { return }
            pendingWorkoutIDs.removeAll()
            resumeTask = nil
            await syncNow(force: true)
        }
    }

    // MARK: - Local truth readers

    private func workout(_ id: UUID) -> WorkoutModel? {
        var descriptor = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// id + updatedAt for every share-eligible workout — the reconcile diff
    /// input. `propertiesToFetch` keeps this a column read, not a
    /// relationship-faulting model load.
    private func eligibleStamps() -> [SocialShareStamp] {
        var descriptor = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.endedAt != nil && $0.deletedAt == nil })
        descriptor.propertiesToFetch = [
            \.id, \.updatedAt, \.endedAt, \.deletedAt,
            \.externalSource, \.importFingerprint, \.importBatchID, \.sourceDevice
        ]
        let rows = (try? context.fetch(descriptor)) ?? []
        // The predicate pre-narrows; SocialBackfill owns the one true
        // eligibility rule so this can never drift from the item builder.
        return SocialBackfill.eligibleWorkouts(rows).map { SocialShareStamp(id: $0.id, updatedAt: $0.updatedAt) }
    }

    private func deletedWorkoutIDs() -> Set<UUID> {
        var descriptor = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.deletedAt != nil })
        descriptor.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
    }

    /// Sanitized share payloads for exactly the requested workouts, read
    /// fresh from the store so a drain always publishes current content.
    private func makeItems(for ids: Set<UUID>) -> [SocialBackfillItem] {
        guard !ids.isEmpty else { return [] }
        let idList = Array(ids)
        let descriptor = FetchDescriptor<WorkoutModel>(predicate: #Predicate { idList.contains($0.id) })
        let workouts = (try? context.fetch(descriptor)) ?? []
        let names = exerciseNames()
        return SocialBackfill.items(from: workouts, exerciseNames: names)
    }

    private func exerciseNames() -> [UUID: String] {
        var descriptor = FetchDescriptor<ExerciseLibraryModel>()
        descriptor.propertiesToFetch = [\.id, \.name]
        let rows = (try? context.fetch(descriptor)) ?? []
        return Dictionary(rows.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
