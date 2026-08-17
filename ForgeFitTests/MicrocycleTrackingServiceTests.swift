import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleTrackingServiceTests {
    private enum ForcedSaveFailure: Error {
        case failed
    }

    private let timeZone = TimeZone(identifier: "America/New_York")!

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour
        ))!
    }

    @Test func startPersistsTenDayTargetAndFrozenRoutineOrder() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Upper Lower")
        let lower = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Lower",
            folderID: folder.id,
            position: 1
        )
        let upper = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id,
            position: 0
        )
        context.insert(folder)
        context.insert(lower)
        context.insert(upper)
        try context.save()

        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [lower, upper],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 8),
            timeZone: timeZone
        )
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
        let window = try #require(windows.first)

        #expect(folder.defaultMicrocycleLengthDays == 10)
        #expect(tracking.anchorDate == date(2026, 8, 1, 0))
        #expect(tracking.durationDays == 10)
        #expect(tracking.showsOnHome)
        #expect(tracking.showsFolderHeader)
        #expect(window.index == 0)
        #expect(window.routines.map(\.name) == ["Upper", "Lower"])
        #expect(MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: windows,
            now: date(2026, 8, 8)
        )?.id == window.id)
    }

    @Test func rolloverKeepsOldSnapshotAndFreezesNewRoutineList() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Six Sessions")
        let first = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "A",
            folderID: folder.id,
            position: 0
        )
        let second = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "B",
            folderID: folder.id,
            position: 1
        )
        context.insert(folder)
        context.insert(first)
        context.insert(second)
        try context.save()

        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [first, second],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let third = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "C",
            folderID: folder.id,
            position: 2
        )
        context.insert(third)
        try context.save()

        _ = try MicrocycleTrackingService.reconcile(
            in: context,
            now: date(2026, 8, 12)
        )
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id }
            .sorted { $0.index < $1.index }

        #expect(windows.count == 2)
        #expect(windows[0].routines.map(\.name) == ["A", "B"])
        #expect(windows[1].routines.map(\.name) == ["A", "B", "C"])
        #expect(windows[1].startsAt == windows[0].endsAt)
    }

    @Test func currentWindowTracksRoutineAddsRemovalsMovesAndRenames() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let trackedFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Tracked")
        let otherFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Other")
        let first = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "A",
            folderID: trackedFolder.id,
            position: 0
        )
        context.insert(trackedFolder)
        context.insert(otherFolder)
        context.insert(first)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: trackedFolder,
            routines: [first],
            folders: [trackedFolder, otherFolder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )

        let added = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "B",
            folderID: trackedFolder.id,
            position: 1
        )
        context.insert(added)
        first.name = "A Updated"
        first.updatedAt = date(2026, 8, 2)
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 2))

        var current = try #require(MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: try context.fetch(FetchDescriptor<MicrocycleWindowModel>()),
            now: date(2026, 8, 2)
        ))
        #expect(current.routines.map(\.name) == ["A Updated", "B"])

        first.folderID = otherFolder.id
        first.updatedAt = date(2026, 8, 3)
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 3))

        current = try #require(MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: try context.fetch(FetchDescriptor<MicrocycleWindowModel>()),
            now: date(2026, 8, 3)
        ))
        #expect(current.routines.map(\.name) == ["B"])

        added.deletedAt = date(2026, 8, 4)
        added.updatedAt = date(2026, 8, 4)
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 4))
        #expect(tracking.needsAttention)
        current = try #require(MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: try context.fetch(FetchDescriptor<MicrocycleWindowModel>()),
            now: date(2026, 8, 4)
        ))
        #expect(current.routines.isEmpty)
    }

    @Test func isolatedReconcileRefreshesPersistedRoutineOrderInTheActiveWindow() throws {
        let (container, context) = try TestStore.make()
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Tracked")
        let first = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "A",
            folderID: folder.id,
            position: 0
        )
        let second = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "B",
            folderID: folder.id,
            position: 1
        )
        context.insert(folder)
        context.insert(first)
        context.insert(second)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [first, second],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )

        // This is the organizer's durable projection: positions are swapped
        // before the app's isolated lifecycle reconciliation refreshes the
        // active microcycle checklist.
        first.position = 1
        first.updatedAt = date(2026, 8, 2)
        second.position = 0
        second.updatedAt = date(2026, 8, 2)
        try context.save()
        _ = try MicrocycleTrackingService.reconcileIsolated(
            from: context,
            now: date(2026, 8, 2)
        )

        let fresh = ModelContext(container)
        let persistedTracking = try #require(
            fresh.fetch(FetchDescriptor<MicrocycleTrackingModel>())
                .first(where: { $0.id == tracking.id })
        )
        let current = try #require(MicrocycleTrackingService.currentWindow(
            for: persistedTracking,
            windows: try fresh.fetch(FetchDescriptor<MicrocycleWindowModel>()),
            now: date(2026, 8, 2)
        ))
        #expect(current.routines.map(\.name) == ["B", "A"])
        #expect(current.routines.map(\.position) == [0, 1])
    }

    @Test func colocatedAlternatesFreezeAsOneRequirementAndEitherMemberCompletesIt() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Conditioning")
        let owner = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "AX400",
            folderID: folder.id,
            position: 0
        )
        let partner = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Cindy",
            folderID: folder.id,
            position: 1
        )
        let strength = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Strength",
            folderID: folder.id,
            position: 2
        )
        let alternation = RoutineAlternationModel(
            userID: ForgeFitDemo.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id
        )
        context.insert(folder)
        context.insert(owner)
        context.insert(partner)
        context.insert(strength)
        context.insert(alternation)
        try context.save()

        _ = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [owner, partner, strength],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let window = try #require(try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first)

        #expect(window.routines.map(\.name) == ["AX400", "Strength"])
        #expect(window.routines.first?.alternateRoutineID == partner.id)
        #expect(window.routines.first?.alternateRoutineName == "Cindy")

        let completedPartner = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: partner.id,
            startedAt: date(2026, 8, 3),
            endedAt: date(2026, 8, 3, 13)
        )
        let repeatedOwner = WorkoutModel(
            userID: ForgeFitDemo.userID,
            routineID: owner.id,
            startedAt: date(2026, 8, 4),
            endedAt: date(2026, 8, 4, 13)
        )
        let progress = MicrocycleTrackingService.progress(
            for: window,
            workouts: [completedPartner, repeatedOwner]
        )

        #expect(progress.requiredCount == 2)
        #expect(progress.completedCount == 1)
        #expect(progress.routines.first?.completedRoutineID == partner.id)
    }

    @Test func aPartnerInAnotherMicrocycleRemainsItsOwnRequirementThere() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let ownerFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Owner Week")
        let partnerFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Partner Week")
        let owner = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "AX400",
            folderID: ownerFolder.id
        )
        let partner = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Cindy",
            folderID: partnerFolder.id
        )
        let alternation = RoutineAlternationModel(
            userID: ForgeFitDemo.userID,
            ownerRoutineID: owner.id,
            partnerRoutineID: partner.id
        )
        context.insert(ownerFolder)
        context.insert(partnerFolder)
        context.insert(owner)
        context.insert(partner)
        context.insert(alternation)
        try context.save()

        _ = try MicrocycleTrackingService.start(
            folder: partnerFolder,
            routines: [owner, partner],
            folders: [ownerFolder, partnerFolder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let window = try #require(try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first)

        #expect(window.routines.count == 1)
        #expect(window.routines.first?.id == partner.id)
        #expect(window.routines.first?.alternateRoutineID == nil)
    }

    @Test func completedRoutineCountsOnceAndDoesNotRollTheWindowEarly() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Two Day")
        let first = RoutineModel(userID: ForgeFitDemo.userID, name: "A", folderID: folder.id)
        let second = RoutineModel(userID: ForgeFitDemo.userID, name: "B", folderID: folder.id, position: 1)
        context.insert(folder)
        context.insert(first)
        context.insert(second)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [first, second],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let window = try #require(try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first)
        let workouts = [
            WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: first.id,
                startedAt: date(2026, 8, 2),
                endedAt: date(2026, 8, 2, 13)
            ),
            WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: first.id,
                startedAt: date(2026, 8, 3),
                endedAt: date(2026, 8, 3, 13)
            ),
            WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: second.id,
                startedAt: date(2026, 8, 4),
                endedAt: date(2026, 8, 4, 13)
            ),
        ]
        let progress = MicrocycleTrackingService.progress(for: window, workouts: workouts)

        #expect(progress.isComplete)
        #expect(progress.completedCount == 2)
        #expect(MicrocycleTrackingService.currentWindow(
            for: tracking,
            windows: [window],
            now: date(2026, 8, 9)
        )?.index == 0)
    }

    @Test func unavailableOrEmptyFolderNeedsAttentionAndCanRecover() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Plan")
        let routine = RoutineModel(userID: ForgeFitDemo.userID, name: "A", folderID: folder.id)
        context.insert(folder)
        context.insert(routine)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )

        folder.deletedAt = date(2026, 8, 2)
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 2))
        #expect(tracking.needsAttention)

        folder.deletedAt = nil
        folder.archivedAt = date(2026, 8, 3)
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 3))
        #expect(tracking.needsAttention)

        folder.archivedAt = nil
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 4))
        #expect(tracking.isActive)

        routine.deletedAt = date(2026, 8, 5)
        try context.save()
        _ = try MicrocycleTrackingService.reconcile(in: context, now: date(2026, 8, 5))
        #expect(tracking.needsAttention)
    }

    @Test func aNewTrackingRunEndsTheOldOneAndDisplayFlagsStayIndependent() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let firstFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "First")
        let secondFolder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Second")
        let firstRoutine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "A",
            folderID: firstFolder.id
        )
        let secondRoutine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "B",
            folderID: secondFolder.id
        )
        context.insert(firstFolder)
        context.insert(secondFolder)
        context.insert(firstRoutine)
        context.insert(secondRoutine)
        try context.save()

        let first = try MicrocycleTrackingService.start(
            folder: firstFolder,
            routines: [firstRoutine, secondRoutine],
            folders: [firstFolder, secondFolder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let second = try MicrocycleTrackingService.start(
            folder: secondFolder,
            routines: [firstRoutine, secondRoutine],
            folders: [firstFolder, secondFolder],
            startDate: date(2026, 8, 2),
            durationDays: 8,
            in: context,
            now: date(2026, 8, 2),
            timeZone: timeZone
        )

        #expect(!first.isActive)
        #expect(first.stateRaw == "ended")
        #expect(second.isActive)
        #expect(MicrocycleTrackingService.activeTracking([first, second])?.id == second.id)

        try MicrocycleTrackingService.setPresentation(
            second,
            showsOnHome: false,
            in: context,
            now: date(2026, 8, 3)
        )
        #expect(!second.showsOnHome)
        #expect(second.showsFolderHeader)
        try MicrocycleTrackingService.setPresentation(
            second,
            showsFolderHeader: false,
            in: context,
            now: date(2026, 8, 4)
        )
        #expect(!second.showsOnHome)
        #expect(!second.showsFolderHeader)
        try MicrocycleTrackingService.setPresentation(
            second,
            showsOnHome: true,
            in: context,
            now: date(2026, 8, 5)
        )
        #expect(second.showsOnHome)
        #expect(!second.showsFolderHeader)
    }

    @Test func editingDayTargetPreservesAssignmentsAndUsesNewLengthGoingForward() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Nine Day")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()

        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 2),
            timeZone: timeZone
        )
        let firstWindow = try #require(
            try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first
        )
        let assignment = MicrocycleDayAssignment(
            day: date(2026, 8, 2, 0),
            workoutID: UUID(),
            assignedAt: date(2026, 8, 3)
        )
        firstWindow.dayAssignments = [assignment]
        try context.save()

        try MicrocycleTrackingService.updateDuration(
            tracking,
            durationDays: 9,
            in: context,
            now: date(2026, 8, 4)
        )

        #expect(tracking.durationDays == 9)
        #expect(folder.defaultMicrocycleLengthDays == 9)
        #expect(firstWindow.startsAt == date(2026, 8, 1, 0))
        #expect(firstWindow.endsAt == date(2026, 8, 10, 0))
        #expect(firstWindow.dayAssignments == [assignment])

        _ = try MicrocycleTrackingService.reconcile(
            in: context,
            now: date(2026, 8, 10)
        )
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id }
            .sorted { $0.index < $1.index }
        #expect(windows.count == 2)
        #expect(windows[1].startsAt == date(2026, 8, 10, 0))
        #expect(windows[1].endsAt == date(2026, 8, 19, 0))
        #expect(MicrocycleTrackingService.windowDurationDays(for: windows[1]) == 9)
    }

    @Test func shorteningCurrentCycleNeverRemovesAnElapsedDay() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Late Edit")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 10,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let firstWindow = try #require(
            try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first
        )

        try MicrocycleTrackingService.updateDuration(
            tracking,
            durationDays: 9,
            in: context,
            now: date(2026, 8, 10)
        )

        #expect(tracking.durationDays == 9)
        #expect(firstWindow.endsAt == date(2026, 8, 11, 0))
        #expect(MicrocycleTrackingService.windowDurationDays(for: firstWindow) == 10)

        _ = try MicrocycleTrackingService.reconcile(
            in: context,
            now: date(2026, 8, 11)
        )
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id }
            .sorted { $0.index < $1.index }
        #expect(windows[1].startsAt == date(2026, 8, 11, 0))
        #expect(windows[1].endsAt == date(2026, 8, 20, 0))
    }

    @Test func addingADayExtendsOnlyTheCurrentCycle() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Rest Flex")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 9,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let firstWindow = try #require(
            try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first
        )

        try MicrocycleTrackingService.addDayToCurrentWindow(
            tracking,
            in: context,
            now: date(2026, 8, 3)
        )

        #expect(tracking.durationDays == 9)
        #expect(folder.defaultMicrocycleLengthDays == 9)
        #expect(firstWindow.endsAt == date(2026, 8, 11, 0))
        #expect(MicrocycleTrackingService.windowDurationDays(for: firstWindow) == 10)

        _ = try MicrocycleTrackingService.reconcile(
            in: context,
            now: date(2026, 8, 11)
        )
        let windows = try context.fetch(FetchDescriptor<MicrocycleWindowModel>())
            .filter { $0.trackingID == tracking.id }
            .sorted { $0.index < $1.index }
        #expect(windows.count == 2)
        #expect(windows[1].startsAt == date(2026, 8, 11, 0))
        #expect(windows[1].endsAt == date(2026, 8, 20, 0))
        #expect(MicrocycleTrackingService.windowDurationDays(for: windows[1]) == 9)
    }

    @Test func failedStartLeavesNoTrackingWindowOrFolderMutation() throws {
        let (container, context) = try TestStore.make()
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Upper")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()
        let originalUpdatedAt = folder.updatedAt

        #expect(throws: ForcedSaveFailure.self) {
            try MicrocycleTrackingService.start(
                folder: folder,
                routines: [routine],
                folders: [folder],
                startDate: date(2026, 8, 1),
                durationDays: 9,
                in: context,
                now: date(2026, 8, 1),
                timeZone: timeZone,
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }
        #expect(folder.defaultMicrocycleLengthDays == nil)
        #expect(folder.updatedAt == originalUpdatedAt)
        #expect(try context.fetch(FetchDescriptor<MicrocycleTrackingModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).isEmpty)

        try context.save()
        let freshContext = ModelContext(container)
        #expect(try freshContext.fetch(FetchDescriptor<MicrocycleTrackingModel>()).isEmpty)
        #expect(try freshContext.fetch(FetchDescriptor<MicrocycleWindowModel>()).isEmpty)
        let persistedFolder = try #require(
            freshContext.fetch(FetchDescriptor<RoutineFolderModel>()).first
        )
        #expect(persistedFolder.defaultMicrocycleLengthDays == nil)
    }

    @Test func failedEndAndAddDayRestoreTheActiveRunBeforeAnyLaterSave() throws {
        let (container, context) = try TestStore.make()
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Upper")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()
        let tracking = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 9,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )
        let window = try #require(
            try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).first
        )
        let originalEnd = window.endsAt
        let originalTrackingUpdatedAt = tracking.updatedAt

        #expect(throws: ForcedSaveFailure.self) {
            try MicrocycleTrackingService.addDayToCurrentWindow(
                tracking,
                in: context,
                now: date(2026, 8, 3),
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }
        #expect(window.endsAt == originalEnd)
        #expect(tracking.updatedAt == originalTrackingUpdatedAt)

        #expect(throws: ForcedSaveFailure.self) {
            try MicrocycleTrackingService.end(
                tracking,
                in: context,
                now: date(2026, 8, 3),
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }
        #expect(tracking.isActive)
        #expect(tracking.endedAt == nil)
        #expect(tracking.updatedAt == originalTrackingUpdatedAt)

        try context.save()
        let freshContext = ModelContext(container)
        let persistedTracking = try #require(
            freshContext.fetch(FetchDescriptor<MicrocycleTrackingModel>()).first
        )
        let persistedWindow = try #require(
            freshContext.fetch(FetchDescriptor<MicrocycleWindowModel>()).first
        )
        #expect(persistedTracking.isActive)
        #expect(persistedWindow.endsAt == originalEnd)
    }

    @Test func failedRolloverRemovesThePendingNextWindow() throws {
        let (container, context) = try TestStore.make()
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Upper")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Upper",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()
        _ = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 2,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )

        #expect(throws: ForcedSaveFailure.self) {
            try MicrocycleTrackingService.reconcile(
                in: context,
                now: date(2026, 8, 4),
                save: { _ in throw ForcedSaveFailure.failed }
            )
        }
        #expect(try context.fetch(FetchDescriptor<MicrocycleWindowModel>()).count == 1)

        try context.save()
        let freshContext = ModelContext(container)
        #expect(try freshContext.fetch(FetchDescriptor<MicrocycleWindowModel>()).count == 1)
    }

    @Test func automaticReconcileDoesNotCommitAnUnrelatedMainContextEdit() throws {
        let (container, context) = try TestStore.make()
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Upper")
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Durable Name",
            folderID: folder.id
        )
        context.insert(folder)
        context.insert(routine)
        try context.save()
        _ = try MicrocycleTrackingService.start(
            folder: folder,
            routines: [routine],
            folders: [folder],
            startDate: date(2026, 8, 1),
            durationDays: 9,
            in: context,
            now: date(2026, 8, 1),
            timeZone: timeZone
        )

        routine.name = "Pending Editor Name"
        _ = try MicrocycleTrackingService.reconcileIsolated(
            from: context,
            now: date(2026, 8, 2)
        )

        let freshContext = ModelContext(container)
        let persistedRoutine = try #require(
            freshContext.fetch(FetchDescriptor<RoutineModel>()).first
        )
        #expect(persistedRoutine.name == "Durable Name")
        #expect(routine.name == "Pending Editor Name")
    }
}
