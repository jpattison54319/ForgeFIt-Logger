import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

struct MicrocyclePlanProgressTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func onlyTheRestMarkerBoundToThePlannedSlotCompletesIt() {
        let routine = MicrocycleRoutineSnapshot(id: UUID(), name: "A", position: 0)
        let plannedID = UUID()
        let linkedRestID = UUID()
        let window = MicrocycleWindowModel(
            userID: UUID(),
            trackingID: UUID(),
            folderID: UUID(),
            folderName: "Cycle",
            index: 0,
            startsAt: start,
            endsAt: start.addingTimeInterval(7 * 24 * 60 * 60),
            timeZoneIdentifier: "UTC",
            routines: [routine],
            plannedRestDays: [.init(
                id: plannedID,
                position: 1,
                completedRestDayID: linkedRestID,
                completedAt: start.addingTimeInterval(24 * 60 * 60)
            )]
        )
        let routineProgress = MicrocycleProgress(
            window: .init(index: 0, startsAt: window.startsAt, endsAt: window.endsAt),
            routines: [.init(
                routine: routine,
                workoutID: UUID(),
                completedAt: start,
                completedRoutineID: routine.id
            )]
        )
        let adHoc = RestDayModel(
            id: UUID(),
            userID: UUID(),
            date: start.addingTimeInterval(12 * 60 * 60),
            timeZoneIdentifier: "UTC"
        )
        let linked = RestDayModel(
            id: linkedRestID,
            userID: UUID(),
            date: start.addingTimeInterval(24 * 60 * 60),
            timeZoneIdentifier: "UTC"
        )

        let withoutLinked = MicrocyclePlanProgress.make(
            window: window,
            routineProgress: routineProgress,
            restDays: [adHoc]
        )
        let withLinked = MicrocyclePlanProgress.make(
            window: window,
            routineProgress: routineProgress,
            restDays: [adHoc, linked]
        )

        #expect(withoutLinked.completedCount == 1)
        #expect(withoutLinked.requiredCount == 2)
        #expect(withLinked.completedCount == 2)
        #expect(withLinked.isComplete)
    }

    @Test func deletingTheLinkedCalendarRestReopensThePlannedSlot() {
        let routine = MicrocycleRoutineSnapshot(id: UUID(), name: "A", position: 0)
        let linkedRestID = UUID()
        let window = MicrocycleWindowModel(
            userID: UUID(),
            trackingID: UUID(),
            folderID: UUID(),
            folderName: "Cycle",
            index: 0,
            startsAt: start,
            endsAt: start.addingTimeInterval(7 * 24 * 60 * 60),
            timeZoneIdentifier: "UTC",
            routines: [routine],
            plannedRestDays: [.init(
                position: 1,
                completedRestDayID: linkedRestID,
                completedAt: start
            )]
        )
        let deleted = RestDayModel(
            id: linkedRestID,
            userID: UUID(),
            date: start,
            timeZoneIdentifier: "UTC",
            deletedAt: start.addingTimeInterval(60)
        )
        let routineProgress = MicrocycleProgress(
            window: .init(index: 0, startsAt: window.startsAt, endsAt: window.endsAt),
            routines: [.init(routine: routine, workoutID: nil, completedAt: nil)]
        )

        let result = MicrocyclePlanProgress.make(
            window: window,
            routineProgress: routineProgress,
            restDays: [deleted]
        )

        #expect(result.completedCount == 0)
        #expect(!result.isComplete)
    }
}
