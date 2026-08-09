import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleTrackingServiceTests {
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
}
