import Foundation
import Testing
@testable import ForgeCore

struct MicrocycleEngineTests {
    private let timeZone = "America/New_York"
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
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

    @Test func tenDayWindowsRepeatFromTheAnchor() throws {
        let anchor = date(2026, 8, 1)
        let first = try MicrocycleEngine.window(
            anchor: anchor,
            durationDays: 10,
            containing: date(2026, 8, 10),
            timeZoneIdentifier: timeZone
        )
        let second = try MicrocycleEngine.window(
            anchor: anchor,
            durationDays: 10,
            containing: date(2026, 8, 11),
            timeZoneIdentifier: timeZone
        )

        #expect(first.index == 0)
        #expect(first.startsAt == date(2026, 8, 1, 0))
        #expect(first.endsAt == date(2026, 8, 11, 0))
        #expect(second.index == 1)
        #expect(second.startsAt == first.endsAt)
    }

    @Test func calendarDaysRemainStableAcrossSpringDST() throws {
        let window = try MicrocycleEngine.window(
            anchor: date(2026, 3, 7),
            durationDays: 3,
            index: 0,
            timeZoneIdentifier: timeZone
        )

        #expect(window.startsAt == date(2026, 3, 7, 0))
        #expect(window.endsAt == date(2026, 3, 10, 0))
        #expect(window.endsAt.timeIntervalSince(window.startsAt) == 71 * 60 * 60)
    }

    @Test func completionCountsEachRoutineOnce() throws {
        let firstID = UUID()
        let secondID = UUID()
        let window = try MicrocycleEngine.window(
            anchor: date(2026, 8, 1),
            durationDays: 10,
            index: 0,
            timeZoneIdentifier: timeZone
        )
        let routines = [
            MicrocycleRoutineSnapshot(id: firstID, name: "Upper", position: 0),
            MicrocycleRoutineSnapshot(id: secondID, name: "Lower", position: 1),
        ]
        let workouts = [
            MicrocycleWorkoutEvidence(id: UUID(), routineID: firstID, startedAt: date(2026, 8, 2), isCompleted: true),
            MicrocycleWorkoutEvidence(id: UUID(), routineID: firstID, startedAt: date(2026, 8, 4), isCompleted: true),
            MicrocycleWorkoutEvidence(id: UUID(), routineID: secondID, startedAt: date(2026, 8, 5), isCompleted: false),
        ]

        let result = MicrocycleEngine.progress(window: window, routines: routines, workouts: workouts)

        #expect(result.completedCount == 1)
        #expect(result.routines[0].completedAt == date(2026, 8, 2))
        #expect(!result.routines[1].isCompleted)
    }

    @Test func deletedAndOutOfWindowWorkoutsDoNotCount() throws {
        let routineID = UUID()
        let window = try MicrocycleEngine.window(
            anchor: date(2026, 8, 1),
            durationDays: 10,
            index: 0,
            timeZoneIdentifier: timeZone
        )
        let routine = MicrocycleRoutineSnapshot(id: routineID, name: "Run", position: 0)
        let workouts = [
            MicrocycleWorkoutEvidence(id: UUID(), routineID: routineID, startedAt: date(2026, 7, 31), isCompleted: true),
            MicrocycleWorkoutEvidence(id: UUID(), routineID: routineID, startedAt: date(2026, 8, 2), isCompleted: true, isDeleted: true),
            MicrocycleWorkoutEvidence(id: UUID(), routineID: nil, startedAt: date(2026, 8, 3), isCompleted: true),
        ]

        let result = MicrocycleEngine.progress(window: window, routines: [routine], workouts: workouts)

        #expect(result.completedCount == 0)
    }

    @Test func eitherAlternatingMemberCompletesOneSlot() throws {
        let ownerID = UUID()
        let partnerID = UUID()
        let window = try MicrocycleEngine.window(
            anchor: date(2026, 8, 1),
            durationDays: 10,
            index: 0,
            timeZoneIdentifier: timeZone
        )
        let slot = MicrocycleRoutineSnapshot(
            id: ownerID,
            name: "AX400",
            position: 0,
            alternateRoutineID: partnerID,
            alternateRoutineName: "Cindy"
        )
        let workout = MicrocycleWorkoutEvidence(
            id: UUID(),
            routineID: partnerID,
            startedAt: date(2026, 8, 3),
            isCompleted: true
        )

        let result = MicrocycleEngine.progress(window: window, routines: [slot], workouts: [workout])

        #expect(result.requiredCount == 1)
        #expect(result.completedCount == 1)
        #expect(result.routines.first?.completedRoutineID == partnerID)
    }

    @Test func anyMemberOfAnAlternatingGroupCompletesOneSlot() throws {
        let ownerID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let window = try MicrocycleEngine.window(
            anchor: date(2026, 8, 1),
            durationDays: 10,
            index: 0,
            timeZoneIdentifier: timeZone
        )
        let slot = MicrocycleRoutineSnapshot(
            id: ownerID,
            name: "A",
            position: 0,
            alternateRoutineID: secondID,
            alternateRoutineName: "B",
            memberRoutineIDs: [ownerID, secondID, thirdID],
            memberRoutineNames: ["A", "B", "C"]
        )
        let workout = MicrocycleWorkoutEvidence(
            id: UUID(),
            routineID: thirdID,
            startedAt: date(2026, 8, 3),
            isCompleted: true
        )

        let result = MicrocycleEngine.progress(
            window: window,
            routines: [slot],
            workouts: [workout]
        )

        #expect(result.requiredCount == 1)
        #expect(result.completedCount == 1)
        #expect(result.routines.first?.completedRoutineID == thirdID)
        #expect(slot.memberName(for: thirdID) == "C")
    }

    @Test func dateBeforeAnchorFailsClosed() {
        #expect(throws: MicrocycleEngine.Error.dateBeforeAnchor) {
            try MicrocycleEngine.window(
                anchor: date(2026, 8, 10),
                durationDays: 10,
                containing: date(2026, 8, 9),
                timeZoneIdentifier: timeZone
            )
        }
    }
}
