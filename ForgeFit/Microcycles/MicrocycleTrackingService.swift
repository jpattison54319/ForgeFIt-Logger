import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum MicrocycleTrackingService {
    typealias SaveOperation = @MainActor (ModelContext) throws -> Void

    enum ServiceError: LocalizedError, Equatable {
        case folderUnavailable
        case folderIsMesocycle
        case emptyMicrocycle
        case invalidDuration
        case futureStart
        case trackingInactive
        case windowUnavailable
        case tooManyPlannedRestDays

        var errorDescription: String? {
            switch self {
            case .folderUnavailable: "This folder is no longer available."
            case .folderIsMesocycle: "Track one microcycle folder, not its parent mesocycle."
            case .emptyMicrocycle: "Add at least one routine before tracking this microcycle."
            case .invalidDuration: "Choose a cycle length from 1 to 31 days."
            case .futureStart: "A microcycle can start today or on a past date."
            case .trackingInactive: "This microcycle is no longer being tracked."
            case .windowUnavailable: "The current microcycle window is unavailable."
            case .tooManyPlannedRestDays: "A microcycle can contain up to 31 planned rest days."
            }
        }
    }

    static let maximumPlannedRestDays = 31

    @discardableResult
    static func start(
        folder: RoutineFolderModel,
        routines: [RoutineModel],
        folders: [RoutineFolderModel],
        startDate: Date,
        durationDays: Int,
        in context: ModelContext,
        now: Date = .now,
        timeZone: TimeZone = .current,
        save: SaveOperation = { try $0.save() }
    ) throws -> MicrocycleTrackingModel {
        guard folder.deletedAt == nil, folder.archivedAt == nil else {
            throw ServiceError.folderUnavailable
        }
        guard !folders.contains(where: {
            $0.parentID == folder.id && $0.deletedAt == nil && $0.archivedAt == nil
        }) else {
            throw ServiceError.folderIsMesocycle
        }
        let alternations = try context.fetch(FetchDescriptor<RoutineAlternationModel>())
        let availableRoutines = snapshots(
            folderID: folder.id,
            routines: routines,
            alternations: alternations
        )
        guard !availableRoutines.isEmpty else { throw ServiceError.emptyMicrocycle }
        guard (1...31).contains(durationDays) else { throw ServiceError.invalidDuration }

        let timeZoneIdentifier = timeZone.identifier
        let anchor = try MicrocycleEngine.normalizedAnchor(
            startDate,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let today = try MicrocycleEngine.normalizedAnchor(
            now,
            timeZoneIdentifier: timeZoneIdentifier
        )
        guard anchor <= today else { throw ServiceError.futureStart }

        return try withMutationRollback(in: context) {
            let active = try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
                .filter { ($0.isActive || $0.needsAttention) && $0.deletedAt == nil }
            for existing in active {
                existing.stateRaw = "ended"
                existing.endedAt = now
                existing.updatedAt = now
            }

            folder.defaultMicrocycleLengthDays = durationDays
            folder.updatedAt = now

            let tracking = MicrocycleTrackingModel(
                userID: ForgeFitDemo.userID,
                folderID: folder.id,
                folderName: folder.name,
                anchorDate: anchor,
                durationDays: durationDays,
                timeZoneIdentifier: timeZoneIdentifier,
                createdAt: now,
                updatedAt: now
            )
            context.insert(tracking)
            try materializeWindows(
                for: tracking,
                routines: availableRoutines,
                in: context,
                now: now
            )
            try save(context)
            return tracking
        }
    }

    @discardableResult
    static func reconcile(
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> MicrocycleTrackingModel? {
        try withMutationRollback(in: context) {
            try reconcileApplying(in: context, now: now, save: save)
        }
    }

    /// Launch/foreground reconciliation must not save whatever an unrelated
    /// editor currently has pending in the shared main context. A short-lived
    /// context sees only durable inputs and commits only lifecycle mutations.
    @discardableResult
    static func reconcileIsolated(
        from sourceContext: ModelContext,
        now: Date = .now
    ) throws -> Date? {
        let context = ModelContext(sourceContext.container)
        context.autosaveEnabled = false
        _ = try reconcile(in: context, now: now)
        return try nextTransitionDate(in: context, now: now)
    }

    private static func reconcileApplying(
        in context: ModelContext,
        now: Date,
        save: SaveOperation
    ) throws -> MicrocycleTrackingModel? {
        let allTrackings = try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
            .filter { ($0.isActive || $0.needsAttention) && $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let tracking = allTrackings.first else {
            try RestDayService.removeWorkoutConflicts(
                in: context,
                now: now,
                shouldSave: false
            )
            if context.hasChanges { try save(context) }
            return nil
        }

        for duplicate in allTrackings.dropFirst() {
            duplicate.stateRaw = "ended"
            duplicate.endedAt = now
            duplicate.updatedAt = now
        }

        let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
        let folder = folders.first {
            $0.id == tracking.folderID && $0.deletedAt == nil && $0.archivedAt == nil
        }
        let isLeaf = !folders.contains {
            $0.parentID == tracking.folderID && $0.deletedAt == nil && $0.archivedAt == nil
        }
        let routines = try context.fetch(FetchDescriptor<RoutineModel>())
        let alternations = try context.fetch(FetchDescriptor<RoutineAlternationModel>())
        let availableRoutines = snapshots(
            folderID: tracking.folderID,
            routines: routines,
            alternations: alternations
        )

        guard let folder, isLeaf else {
            if tracking.stateRaw != "needsAttention" {
                tracking.stateRaw = "needsAttention"
                tracking.updatedAt = now
            }
            try RestDayService.removeWorkoutConflicts(
                in: context,
                now: now,
                shouldSave: false
            )
            try save(context)
            return tracking
        }

        var changed = false
        if tracking.folderName != folder.name {
            tracking.folderName = folder.name
            changed = true
        }
        guard !availableRoutines.isEmpty else {
            // Removing the final routine empties the live checklist too. The
            // tracking run stays recoverable and returns to active as soon as
            // a routine is added back to the folder.
            changed = try materializeWindows(
                for: tracking,
                routines: [],
                in: context,
                now: now
            ) || changed
            if tracking.stateRaw != "needsAttention" {
                tracking.stateRaw = "needsAttention"
                changed = true
            }
            if changed { tracking.updatedAt = now }
            try RestDayService.removeWorkoutConflicts(
                in: context,
                now: now,
                shouldSave: false
            )
            try save(context)
            return tracking
        }
        if tracking.stateRaw != "active" {
            tracking.stateRaw = "active"
            changed = true
        }
        changed = try materializeWindows(
            for: tracking,
            routines: availableRoutines,
            in: context,
            now: now
        ) || changed
        if changed { tracking.updatedAt = now }
        try RestDayService.removeWorkoutConflicts(
            in: context,
            now: now,
            shouldSave: false
        )
        try save(context)
        return tracking
    }

    static func end(
        _ tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        try withMutationRollback(in: context) {
            tracking.stateRaw = "ended"
            tracking.endedAt = now
            tracking.updatedAt = now
            try save(context)
        }
    }

    static func setPresentation(
        _ tracking: MicrocycleTrackingModel,
        showsOnHome: Bool? = nil,
        showsFolderHeader: Bool? = nil,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        try withMutationRollback(in: context) {
            if let showsOnHome { tracking.showsOnHome = showsOnHome }
            if let showsFolderHeader { tracking.showsFolderHeader = showsFolderHeader }
            tracking.updatedAt = now
            try save(context)
        }
    }

    /// Changes the repeating target without rewriting completed windows. The
    /// active window can shrink only as far as the current day, so every day
    /// the user has already reached or backfilled remains available.
    static func updateDuration(
        _ tracking: MicrocycleTrackingModel,
        durationDays: Int,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard tracking.isActive || tracking.needsAttention else {
            throw ServiceError.trackingInactive
        }
        guard (1...31).contains(durationDays) else {
            throw ServiceError.invalidDuration
        }

        try withMutationRollback(in: context) {
            let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
                .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
            if let current = currentWindow(for: tracking, windows: windows, now: now) {
                let calendar = try MicrocycleEngine.calendar(
                    timeZoneIdentifier: tracking.timeZoneIdentifier
                )
                let currentDuration = windowDurationDays(for: current)
                let temporaryExtension = max(0, currentDuration - tracking.durationDays)
                let elapsedDays = dayNumber(for: current, now: now)
                let requestedDuration = durationDays + temporaryExtension
                let preservedDuration = max(elapsedDays, requestedDuration)
                guard let adjustedEnd = calendar.date(
                    byAdding: .day,
                    value: preservedDuration,
                    to: current.startsAt
                ) else {
                    throw ServiceError.windowUnavailable
                }
                try resize(
                    current,
                    to: adjustedEnd,
                    shifting: windows,
                    calendar: calendar,
                    now: now
                )
            }

            tracking.durationDays = durationDays
            tracking.updatedAt = now
            let folders = try context.fetch(FetchDescriptor<RoutineFolderModel>())
            if let folder = folders.first(where: {
                $0.id == tracking.folderID && $0.deletedAt == nil
            }) {
                folder.defaultMicrocycleLengthDays = durationDays
                folder.updatedAt = now
            }
            try save(context)
        }
    }

    /// Extends only the active window. Later windows, if already present, move
    /// with it; newly materialized windows return to the repeating day target.
    static func addDayToCurrentWindow(
        _ tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard tracking.isActive else { throw ServiceError.trackingInactive }
        try withMutationRollback(in: context) {
            let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
                .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
            guard let current = currentWindow(for: tracking, windows: windows, now: now) else {
                throw ServiceError.windowUnavailable
            }
            let calendar = try MicrocycleEngine.calendar(
                timeZoneIdentifier: tracking.timeZoneIdentifier
            )
            guard let adjustedEnd = calendar.date(
                byAdding: .day,
                value: 1,
                to: current.endsAt
            ) else {
                throw ServiceError.windowUnavailable
            }
            try resize(
                current,
                to: adjustedEnd,
                shifting: windows,
                calendar: calendar,
                now: now
            )
            tracking.updatedAt = now
            try save(context)
        }
    }

    @discardableResult
    static func addPlannedRestDay(
        to tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        id: UUID = UUID(),
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> UUID {
        guard tracking.isActive else { throw ServiceError.trackingInactive }
        return try withMutationRollback(in: context) {
            let window = try currentWindowForMutation(tracking, in: context, now: now)
            guard window.plannedRestDays.count < maximumPlannedRestDays else {
                throw ServiceError.tooManyPlannedRestDays
            }
            window.planSnapshot = window.planSnapshot.addingRestDay(id: id)
            window.updatedAt = now
            tracking.updatedAt = now
            try save(context)
            return id
        }
    }

    static func movePlannedRestDay(
        id: UUID,
        to targetIndex: Int,
        in tracking: MicrocycleTrackingModel,
        context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard tracking.isActive else { throw ServiceError.trackingInactive }
        try withMutationRollback(in: context) {
            let window = try currentWindowForMutation(tracking, in: context, now: now)
            let updated = window.planSnapshot.movingRestDay(id: id, to: targetIndex)
            guard updated != window.planSnapshot else { return }
            window.planSnapshot = updated
            window.updatedAt = now
            tracking.updatedAt = now
            try save(context)
        }
    }

    static func removePlannedRestDay(
        id: UUID,
        from tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard tracking.isActive else { throw ServiceError.trackingInactive }
        try withMutationRollback(in: context) {
            let window = try currentWindowForMutation(tracking, in: context, now: now)
            let updated = window.planSnapshot.removingRestDay(id: id)
            guard updated != window.planSnapshot else { return }
            window.planSnapshot = updated
            window.updatedAt = now
            tracking.updatedAt = now
            try save(context)
        }
    }

    @discardableResult
    static func logPlannedRestDay(
        id: UUID,
        in tracking: MicrocycleTrackingModel,
        workouts: [WorkoutModel],
        context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws -> RestDayModel {
        guard tracking.isActive else { throw ServiceError.trackingInactive }
        return try withMutationRollback(in: context) {
            let window = try currentWindowForMutation(tracking, in: context, now: now)
            guard window.plannedRestDays.contains(where: { $0.id == id }) else {
                throw ServiceError.windowUnavailable
            }
            let timeZone = TimeZone(identifier: tracking.timeZoneIdentifier) ?? .current
            let restDay = try RestDayService.log(
                date: now,
                workouts: workouts,
                in: context,
                now: now,
                timeZone: timeZone,
                save: { _ in }
            )
            window.planSnapshot = window.planSnapshot.completingRestDay(
                id: id,
                with: restDay.id,
                at: restDay.date
            )
            window.updatedAt = now
            tracking.updatedAt = now
            try save(context)
            return restDay
        }
    }

    /// Ends the interrupted window at the start of today and begins the same
    /// tracked microcycle again at Day 1. The plan, history, and repeating day
    /// target remain intact; a temporary extension on this window is retained.
    static func restartCurrentCycle(
        _ tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        now: Date = .now,
        save: SaveOperation = { try $0.save() }
    ) throws {
        guard tracking.isActive else { throw ServiceError.trackingInactive }

        try withMutationRollback(in: context) {
            let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
                .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
            guard let current = currentWindow(for: tracking, windows: windows, now: now) else {
                throw ServiceError.windowUnavailable
            }
            let calendar = try MicrocycleEngine.calendar(
                timeZoneIdentifier: tracking.timeZoneIdentifier
            )
            let restartDate = calendar.startOfDay(for: now)
            guard restartDate > current.startsAt else { return }
            guard !windows.contains(where: { $0.index > current.index }) else {
                throw ServiceError.windowUnavailable
            }

            let durationDays = windowDurationDays(for: current)
            guard let restartedEnd = calendar.date(
                byAdding: .day,
                value: durationDays,
                to: restartDate
            ) else {
                throw ServiceError.windowUnavailable
            }

            current.endsAt = restartDate
            current.updatedAt = now
            let restarted = MicrocycleWindowModel(
                userID: tracking.userID,
                trackingID: tracking.id,
                folderID: tracking.folderID,
                folderName: current.folderName,
                index: current.index + 1,
                startsAt: restartDate,
                endsAt: restartedEnd,
                timeZoneIdentifier: current.timeZoneIdentifier,
                routines: current.routines,
                plannedRestDays: current.planSnapshot
                    .resettingRestDayCompletions()
                    .plannedRestDays,
                createdAt: now,
                updatedAt: now
            )
            context.insert(restarted)
            tracking.updatedAt = now
            try save(context)
        }
    }

    static func activeTracking(_ trackings: [MicrocycleTrackingModel]) -> MicrocycleTrackingModel? {
        trackings
            .filter { ($0.isActive || $0.needsAttention) && $0.deletedAt == nil }
            .max { $0.updatedAt < $1.updatedAt }
    }

    static func currentWindow(
        for tracking: MicrocycleTrackingModel,
        windows: [MicrocycleWindowModel],
        now: Date = .now
    ) -> MicrocycleWindowModel? {
        windows
            .filter {
                $0.trackingID == tracking.id
                    && $0.deletedAt == nil
                    && $0.startsAt <= now
                    && now < $0.endsAt
            }
            .max { $0.index < $1.index }
    }

    static func progress(
        for window: MicrocycleWindowModel,
        windows: [MicrocycleWindowModel]? = nil,
        workouts: [WorkoutModel]
    ) -> MicrocycleProgress {
        let domainWindow = MicrocycleWindow(
            index: window.index,
            startsAt: window.startsAt,
            endsAt: window.endsAt
        )
        // An explicitly backfilled workout is evaluated at its assigned day
        // throughout this tracking run. Because fixed windows do not overlap,
        // this also prevents one workout from counting in both its original
        // window and the window where the user deliberately placed it.
        let relevantWindows = (windows ?? [window]).filter {
            $0.trackingID == window.trackingID && $0.deletedAt == nil
        }
        var effectiveDateByWorkoutID: [UUID: (date: Date, assignedAt: Date, id: UUID)] = [:]
        for assignment in relevantWindows.flatMap(\.dayAssignments) {
            let shouldReplace: Bool
            if let existing = effectiveDateByWorkoutID[assignment.workoutID] {
                shouldReplace = assignment.assignedAt > existing.assignedAt
                    || (assignment.assignedAt == existing.assignedAt
                        && assignment.id.uuidString > existing.id.uuidString)
            } else {
                shouldReplace = true
            }
            if shouldReplace {
                effectiveDateByWorkoutID[assignment.workoutID] = (
                    assignment.day,
                    assignment.assignedAt,
                    assignment.id
                )
            }
        }
        let evidence = workouts.map {
            MicrocycleWorkoutEvidence(
                id: $0.id,
                routineID: $0.routineID,
                startedAt: effectiveDateByWorkoutID[$0.id]?.date ?? $0.startedAt,
                isCompleted: $0.endedAt != nil,
                isDeleted: $0.deletedAt != nil
            )
        }
        return MicrocycleEngine.progress(
            window: domainWindow,
            routines: window.routines,
            workouts: evidence
        )
    }

    static func dayNumber(
        for window: MicrocycleWindowModel,
        now: Date = .now
    ) -> Int {
        guard let calendar = try? MicrocycleEngine.calendar(
            timeZoneIdentifier: window.timeZoneIdentifier
        ) else { return 1 }
        let today = calendar.startOfDay(for: min(max(now, window.startsAt), window.endsAt))
        let elapsed = calendar.dateComponents([.day], from: window.startsAt, to: today).day ?? 0
        return min(max(elapsed + 1, 1), max(1, calendar.dateComponents(
            [.day],
            from: window.startsAt,
            to: window.endsAt
        ).day ?? 1))
    }

    static func windowDurationDays(for window: MicrocycleWindowModel) -> Int {
        guard let calendar = try? MicrocycleEngine.calendar(
            timeZoneIdentifier: window.timeZoneIdentifier
        ) else { return 1 }
        return max(1, calendar.dateComponents(
            [.day],
            from: window.startsAt,
            to: window.endsAt
        ).day ?? 1)
    }

    static func history(
        for tracking: MicrocycleTrackingModel,
        windows: [MicrocycleWindowModel]
    ) -> [MicrocycleWindowModel] {
        windows
            .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
            .sorted { $0.index > $1.index }
    }

    static func nextTransitionDate(
        in context: ModelContext,
        now: Date = .now
    ) throws -> Date? {
        let tracking = activeTracking(
            try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
        )
        guard let tracking, tracking.isActive else { return nil }
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
        return currentWindow(for: tracking, windows: windows, now: now)?.endsAt
    }

    private struct TrackingSnapshot {
        let model: MicrocycleTrackingModel
        let folderName: String
        let anchorDate: Date
        let durationDays: Int
        let timeZoneIdentifier: String
        let stateRaw: String
        let showsOnHome: Bool
        let showsFolderHeader: Bool
        let endedAt: Date?
        let updatedAt: Date
        let deletedAt: Date?

        init(_ model: MicrocycleTrackingModel) {
            self.model = model
            folderName = model.folderName
            anchorDate = model.anchorDate
            durationDays = model.durationDays
            timeZoneIdentifier = model.timeZoneIdentifier
            stateRaw = model.stateRaw
            showsOnHome = model.showsOnHome
            showsFolderHeader = model.showsFolderHeader
            endedAt = model.endedAt
            updatedAt = model.updatedAt
            deletedAt = model.deletedAt
        }

        func restore() {
            model.folderName = folderName
            model.anchorDate = anchorDate
            model.durationDays = durationDays
            model.timeZoneIdentifier = timeZoneIdentifier
            model.stateRaw = stateRaw
            model.showsOnHome = showsOnHome
            model.showsFolderHeader = showsFolderHeader
            model.endedAt = endedAt
            model.updatedAt = updatedAt
            model.deletedAt = deletedAt
        }
    }

    private struct WindowSnapshot {
        let model: MicrocycleWindowModel
        let folderName: String
        let index: Int
        let startsAt: Date
        let endsAt: Date
        let timeZoneIdentifier: String
        let routineSnapshotJSON: String
        let dayAssignmentSnapshotJSON: String
        let updatedAt: Date
        let deletedAt: Date?

        init(_ model: MicrocycleWindowModel) {
            self.model = model
            folderName = model.folderName
            index = model.index
            startsAt = model.startsAt
            endsAt = model.endsAt
            timeZoneIdentifier = model.timeZoneIdentifier
            routineSnapshotJSON = model.routineSnapshotJSON
            dayAssignmentSnapshotJSON = model.dayAssignmentSnapshotJSON
            updatedAt = model.updatedAt
            deletedAt = model.deletedAt
        }

        func restore() {
            model.folderName = folderName
            model.index = index
            model.startsAt = startsAt
            model.endsAt = endsAt
            model.timeZoneIdentifier = timeZoneIdentifier
            model.routineSnapshotJSON = routineSnapshotJSON
            model.dayAssignmentSnapshotJSON = dayAssignmentSnapshotJSON
            model.updatedAt = updatedAt
            model.deletedAt = deletedAt
        }
    }

    private struct FolderSnapshot {
        let model: RoutineFolderModel
        let defaultMicrocycleLengthDays: Int?
        let updatedAt: Date

        init(_ model: RoutineFolderModel) {
            self.model = model
            defaultMicrocycleLengthDays = model.defaultMicrocycleLengthDays
            updatedAt = model.updatedAt
        }

        func restore() {
            model.defaultMicrocycleLengthDays = defaultMicrocycleLengthDays
            model.updatedAt = updatedAt
        }
    }

    private struct RestDaySnapshot {
        let model: RestDayModel
        let deletedAt: Date?
        let updatedAt: Date

        init(_ model: RestDayModel) {
            self.model = model
            deletedAt = model.deletedAt
            updatedAt = model.updatedAt
        }

        func restore() {
            model.deletedAt = deletedAt
            model.updatedAt = updatedAt
        }
    }

    private struct MutationSnapshot {
        let trackings: [TrackingSnapshot]
        let windows: [WindowSnapshot]
        let folders: [FolderSnapshot]
        let restDays: [RestDaySnapshot]
        let trackingIDs: Set<UUID>
        let windowIDs: Set<UUID>
        let restDayIDs: Set<UUID>

        init(context: ModelContext) throws {
            let trackingModels = try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
            let windowModels = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            trackings = trackingModels.map(TrackingSnapshot.init)
            windows = windowModels.map(WindowSnapshot.init)
            folders = try context.fetch(FetchDescriptor<RoutineFolderModel>()).map(FolderSnapshot.init)
            restDays = try context.fetch(FetchDescriptor<RestDayModel>()).map(RestDaySnapshot.init)
            trackingIDs = Set(trackingModels.map(\.id))
            windowIDs = Set(windowModels.map(\.id))
            restDayIDs = Set(restDays.map { $0.model.id })
        }

        func restore(in context: ModelContext) {
            trackings.forEach { $0.restore() }
            windows.forEach { $0.restore() }
            folders.forEach { $0.restore() }
            restDays.forEach { $0.restore() }

            if let currentWindows = try? context.fetch(FetchDescriptor<MicrocycleWindowModel>()) {
                for window in currentWindows where !windowIDs.contains(window.id) {
                    context.delete(window)
                }
            }
            if let currentTrackings = try? context.fetch(FetchDescriptor<MicrocycleTrackingModel>()) {
                for tracking in currentTrackings where !trackingIDs.contains(tracking.id) {
                    context.delete(tracking)
                }
            }
            if let currentRestDays = try? context.fetch(FetchDescriptor<RestDayModel>()) {
                for restDay in currentRestDays where !restDayIDs.contains(restDay.id) {
                    context.delete(restDay)
                }
            }
        }
    }

    private static func withMutationRollback<Result>(
        in context: ModelContext,
        _ operation: () throws -> Result
    ) throws -> Result {
        let snapshot = try MutationSnapshot(context: context)
        do {
            return try operation()
        } catch {
            snapshot.restore(in: context)
            throw error
        }
    }

    private static func currentWindowForMutation(
        _ tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        now: Date
    ) throws -> MicrocycleWindowModel {
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
        guard let window = currentWindow(for: tracking, windows: windows, now: now) else {
            throw ServiceError.windowUnavailable
        }
        return window
    }

    private static func snapshots(
        folderID: UUID,
        routines: [RoutineModel],
        alternations: [RoutineAlternationModel]
    ) -> [MicrocycleRoutineSnapshot] {
        let liveRoutines = RoutineDeduplicator.canonicalRoutines(routines)
            .filter { $0.deletedAt == nil && $0.archivedAt == nil }
        let byID = Dictionary(liveRoutines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pairByOwnerID: [UUID: RoutineModel] = [:]
        var claimedRoutineIDs: Set<UUID> = []
        for alternation in RoutineAlternationService.live(alternations) {
            guard !claimedRoutineIDs.contains(alternation.ownerRoutineID),
                  !claimedRoutineIDs.contains(alternation.partnerRoutineID),
                  let owner = byID[alternation.ownerRoutineID],
                  let partner = byID[alternation.partnerRoutineID],
                  owner.id != partner.id else { continue }
            pairByOwnerID[owner.id] = partner
            claimedRoutineIDs.insert(owner.id)
            claimedRoutineIDs.insert(partner.id)
        }
        let colocatedPartnerIDs: Set<UUID> = Set(pairByOwnerID.compactMap { ownerID, partner -> UUID? in
            guard byID[ownerID]?.folderID == folderID, partner.folderID == folderID else { return nil }
            return partner.id
        })

        return liveRoutines
            .filter {
                $0.folderID == folderID
                    && !colocatedPartnerIDs.contains($0.id)
            }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { routine in
                let partner = pairByOwnerID[routine.id]
                return MicrocycleRoutineSnapshot(
                    id: routine.id,
                    name: routine.name,
                    position: routine.position,
                    alternateRoutineID: partner?.id,
                    alternateRoutineName: partner?.name
                )
            }
    }

    @discardableResult
    private static func materializeWindows(
        for tracking: MicrocycleTrackingModel,
        routines: [MicrocycleRoutineSnapshot],
        in context: ModelContext,
        now: Date
    ) throws -> Bool {
        let calendar = try MicrocycleEngine.calendar(
            timeZoneIdentifier: tracking.timeZoneIdentifier
        )
        var ordered = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
            .sorted {
                if $0.index != $1.index { return $0.index < $1.index }
                return $0.startsAt < $1.startsAt
            }

        var changed = false
        if ordered.isEmpty {
            let first = try MicrocycleEngine.window(
                anchor: tracking.anchorDate,
                durationDays: tracking.durationDays,
                index: 0,
                timeZoneIdentifier: tracking.timeZoneIdentifier
            )
            let model = MicrocycleWindowModel(
                userID: tracking.userID,
                trackingID: tracking.id,
                folderID: tracking.folderID,
                folderName: tracking.folderName,
                index: 0,
                startsAt: first.startsAt,
                endsAt: first.endsAt,
                timeZoneIdentifier: tracking.timeZoneIdentifier,
                routines: routines,
                createdAt: now,
                updatedAt: now
            )
            context.insert(model)
            ordered.append(model)
            changed = true
        }

        // Stored boundaries, rather than anchor arithmetic, are the schedule
        // source of truth. This lets one active window gain a rest day without
        // changing the repeating duration of every window that follows.
        while let previous = ordered.last, now >= previous.endsAt {
            guard let nextEnd = calendar.date(
                byAdding: .day,
                value: tracking.durationDays,
                to: previous.endsAt
            ) else {
                throw ServiceError.windowUnavailable
            }
            let model = MicrocycleWindowModel(
                userID: tracking.userID,
                trackingID: tracking.id,
                folderID: tracking.folderID,
                folderName: tracking.folderName,
                index: previous.index + 1,
                startsAt: previous.endsAt,
                endsAt: nextEnd,
                timeZoneIdentifier: tracking.timeZoneIdentifier,
                routines: routines,
                plannedRestDays: previous.planSnapshot
                    .resettingRestDayCompletions()
                    .plannedRestDays,
                createdAt: now,
                updatedAt: now
            )
            context.insert(model)
            ordered.append(model)
            changed = true
        }

        let currentWindowModel = ordered.last {
            $0.startsAt <= now && now < $0.endsAt
        }

        // The active window is a live checklist: changing the leaf folder's
        // routines must change what is due immediately. Only windows that
        // have already ended remain frozen as historical records.
        if let currentWindowModel,
           currentWindowModel.routines != routines
                || currentWindowModel.folderName != tracking.folderName {
            currentWindowModel.routines = routines
            currentWindowModel.folderName = tracking.folderName
            currentWindowModel.updatedAt = now
            changed = true
        }
        return changed
    }

    private static func resize(
        _ window: MicrocycleWindowModel,
        to adjustedEnd: Date,
        shifting windows: [MicrocycleWindowModel],
        calendar: Calendar,
        now: Date
    ) throws {
        guard adjustedEnd > window.startsAt else {
            throw ServiceError.invalidDuration
        }
        let originalEnd = window.endsAt
        let dayDelta = calendar.dateComponents(
            [.day],
            from: originalEnd,
            to: adjustedEnd
        ).day ?? 0
        guard dayDelta != 0 else { return }

        window.endsAt = adjustedEnd
        window.updatedAt = now
        let followingWindows = windows
            .filter { $0.index > window.index }
            .sorted { $0.index < $1.index }
        for following in followingWindows {
            guard let shiftedStart = calendar.date(
                byAdding: .day,
                value: dayDelta,
                to: following.startsAt
            ), let shiftedEnd = calendar.date(
                byAdding: .day,
                value: dayDelta,
                to: following.endsAt
            ) else {
                throw ServiceError.windowUnavailable
            }
            following.startsAt = shiftedStart
            following.endsAt = shiftedEnd
            following.updatedAt = now
        }
    }
}
