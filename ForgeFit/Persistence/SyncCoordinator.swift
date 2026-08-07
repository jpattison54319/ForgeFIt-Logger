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

    /// Log-store entities whose changes mean training data moved (backup +
    /// social both key off this set). Analytics caches, insights, plan rows,
    /// and exercise-library edits deliberately don't wake the pipeline.
    private static let logEntities: Set<String> = [
        "WorkoutModel", "WorkoutExerciseModel", "SetModel",
        "CardioSessionModel", "CardioSplitModel", "CardioRoutePointModel"
    ]

    private let social: SocialService
    private let context: ModelContext
    private let debounce: Duration
    private var saveObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    /// Workout ids touched since the last flush, and the flush task itself —
    /// a burst of saves (logging a set every few seconds) coalesces into one
    /// routing pass.
    private var pendingWorkoutIDs: Set<UUID> = []
    private var flushTask: Task<Void, Never>?
    /// Ids whose `updatedAt` the last flush stamped itself: the stamp's own
    /// save echoes through the change feed and must not re-trigger routing.
    private var suppressEcho: Set<UUID> = []

    init(social: SocialService, container: ModelContainer, debounce: Duration = .seconds(2)) {
        self.social = social
        self.context = ModelContext(container)
        self.debounce = debounce
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        pathMonitor?.cancel()
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
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            // Connectivity is back — flush what offline queued up.
            Task { @MainActor [weak self] in await self?.syncNow() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Foreground / launch / opt-in entry point: drain the outbox, then run
    /// the converge pass (throttled unless forced).
    func syncNow(force: Bool = false) async {
        guard social.isOptedIn else { return }
        await social.drainShareOutbox { [weak self] ids in self?.makeItems(for: ids) ?? [] }
        await social.reconcileSharedWorkouts(
            eligible: eligibleStamps(),
            deletedIDs: deletedWorkoutIDs(),
            force: force
        ) { [weak self] ids in self?.makeItems(for: ids) ?? [] }
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
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        let ids = pendingWorkoutIDs
        pendingWorkoutIDs = []
        guard !ids.isEmpty, social.isOptedIn else { return }

        var ops: [UUID: SocialService.ShareOp] = [:]
        var stampsToSave = false
        for id in ids {
            guard let workout = workout(id) else { continue }   // hard-deleted
            if workout.deletedAt != nil {
                ops[id] = .unpublish
            } else if workout.endedAt != nil, !workout.isImportedHistory {
                // The feed saw content change beneath this workout: advance
                // its clock so the share watermark (and reconcile drift
                // detection on other passes) reflect the edit.
                workout.updatedAt = Date()
                suppressEcho.insert(id)
                stampsToSave = true
                ops[id] = .publish
            }
            // In-progress and imported workouts don't touch the community.
        }
        if stampsToSave { try? context.save() }

        social.enqueueShare(ops)
        await social.drainShareOutbox { [weak self] ids in self?.makeItems(for: ids) ?? [] }
    }

    /// Nudges the pending flush to run now (workout finish taps this so the
    /// share appears immediately instead of after the debounce).
    func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
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
