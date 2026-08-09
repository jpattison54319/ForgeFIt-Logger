import ForgeCore
import ForgeData
import Foundation
import SwiftData

@MainActor
enum MicrocycleTrackingService {
    enum ServiceError: LocalizedError, Equatable {
        case folderUnavailable
        case folderIsMesocycle
        case emptyMicrocycle
        case invalidDuration
        case futureStart

        var errorDescription: String? {
            switch self {
            case .folderUnavailable: "This folder is no longer available."
            case .folderIsMesocycle: "Track one microcycle folder, not its parent mesocycle."
            case .emptyMicrocycle: "Add at least one routine before tracking this microcycle."
            case .invalidDuration: "Choose a cycle length from 1 to 31 days."
            case .futureStart: "A microcycle can start today or on a past date."
            }
        }
    }

    @discardableResult
    static func start(
        folder: RoutineFolderModel,
        routines: [RoutineModel],
        folders: [RoutineFolderModel],
        startDate: Date,
        durationDays: Int,
        in context: ModelContext,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) throws -> MicrocycleTrackingModel {
        guard folder.deletedAt == nil, folder.archivedAt == nil else {
            throw ServiceError.folderUnavailable
        }
        guard !folders.contains(where: {
            $0.parentID == folder.id && $0.deletedAt == nil && $0.archivedAt == nil
        }) else {
            throw ServiceError.folderIsMesocycle
        }
        let availableRoutines = snapshots(folderID: folder.id, routines: routines)
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

        let active = try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
            .filter { ($0.isActive || $0.needsAttention) && $0.deletedAt == nil }
        for existing in active {
            existing.stateRaw = "ended"
            existing.endedAt = today
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
        try context.save()
        return tracking
    }

    @discardableResult
    static func reconcile(in context: ModelContext, now: Date = .now) throws -> MicrocycleTrackingModel? {
        let allTrackings = try context.fetch(FetchDescriptor<MicrocycleTrackingModel>())
            .filter { ($0.isActive || $0.needsAttention) && $0.deletedAt == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let tracking = allTrackings.first else {
            try RestDayService.removeWorkoutConflicts(in: context, now: now)
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
        let availableRoutines = snapshots(folderID: tracking.folderID, routines: routines)

        guard let folder, isLeaf else {
            if tracking.stateRaw != "needsAttention" {
                tracking.stateRaw = "needsAttention"
                tracking.updatedAt = now
            }
            try RestDayService.removeWorkoutConflicts(in: context, now: now)
            try context.save()
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
            try RestDayService.removeWorkoutConflicts(in: context, now: now)
            try context.save()
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
        try RestDayService.removeWorkoutConflicts(in: context, now: now)
        try context.save()
        return tracking
    }

    static func end(
        _ tracking: MicrocycleTrackingModel,
        in context: ModelContext,
        now: Date = .now
    ) throws {
        tracking.stateRaw = "ended"
        tracking.endedAt = now
        tracking.updatedAt = now
        try context.save()
    }

    static func setPresentation(
        _ tracking: MicrocycleTrackingModel,
        showsOnHome: Bool? = nil,
        showsFolderHeader: Bool? = nil,
        in context: ModelContext,
        now: Date = .now
    ) throws {
        if let showsOnHome { tracking.showsOnHome = showsOnHome }
        if let showsFolderHeader { tracking.showsFolderHeader = showsFolderHeader }
        tracking.updatedAt = now
        try context.save()
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

    private static func snapshots(
        folderID: UUID,
        routines: [RoutineModel]
    ) -> [MicrocycleRoutineSnapshot] {
        routines
            .filter {
                $0.folderID == folderID
                    && $0.deletedAt == nil
                    && $0.archivedAt == nil
            }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id.uuidString < $1.id.uuidString
            }
            .map { MicrocycleRoutineSnapshot(id: $0.id, name: $0.name, position: $0.position) }
    }

    @discardableResult
    private static func materializeWindows(
        for tracking: MicrocycleTrackingModel,
        routines: [MicrocycleRoutineSnapshot],
        in context: ModelContext,
        now: Date
    ) throws -> Bool {
        let current = try MicrocycleEngine.window(
            anchor: tracking.anchorDate,
            durationDays: tracking.durationDays,
            containing: now,
            timeZoneIdentifier: tracking.timeZoneIdentifier
        )
        let existing = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id && $0.deletedAt == nil }
        let existingIndices = Set(existing.map(\.index))
        var currentWindowModel = existing.first { $0.index == current.index }

        var changed = false
        for index in 0...current.index where !existingIndices.contains(index) {
            let window = try MicrocycleEngine.window(
                anchor: tracking.anchorDate,
                durationDays: tracking.durationDays,
                index: index,
                timeZoneIdentifier: tracking.timeZoneIdentifier
            )
            let model = MicrocycleWindowModel(
                userID: tracking.userID,
                trackingID: tracking.id,
                folderID: tracking.folderID,
                folderName: tracking.folderName,
                index: index,
                startsAt: window.startsAt,
                endsAt: window.endsAt,
                timeZoneIdentifier: tracking.timeZoneIdentifier,
                routines: routines,
                createdAt: now,
                updatedAt: now
            )
            context.insert(model)
            if index == current.index { currentWindowModel = model }
            changed = true
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
}
