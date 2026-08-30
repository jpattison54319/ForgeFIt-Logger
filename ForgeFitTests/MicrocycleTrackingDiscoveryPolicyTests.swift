import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct MicrocycleTrackingDiscoveryPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test func offersAfterThreeNewForgeFitWorkoutsInNineCalendarDays() throws {
        let library = makeLibrary(name: "Strength Cycle")
        let decision = evaluate(
            workouts: workouts(for: library.routine, daysAgo: [8, 4, 0]),
            library: library,
            enrolledAt: day(-10)
        )

        let offer = try #require(decision.offer)
        #expect(offer.targetID == library.folder.id)
        #expect(offer.whyNow == "You’ve trained Strength Cycle 3 times in the last 9 days.")
    }

    @Test func ignoresPreEnrollmentImportedDeletedAndUnfinishedWorkouts() {
        let library = makeLibrary()
        var candidates = workouts(for: library.routine, daysAgo: [2, 1, 0])
        candidates[0].externalSource = "hevy"
        candidates[1].deletedAt = now
        candidates[2].endedAt = nil
        candidates.append(contentsOf: workouts(for: library.routine, daysAgo: [6, 5, 4]))

        let decision = evaluate(
            workouts: candidates.sorted { $0.startedAt > $1.startedAt },
            library: library,
            enrolledAt: day(-3)
        )

        #expect(decision == .doNotOffer(.noQualifyingTarget))
    }

    @Test func ignoresSourceDeviceOnlyImports() {
        let library = makeLibrary()
        let importedSources = ["healthkit-workout", "import-json", "gpx-import"]
        let candidates = zip(
            workouts(for: library.routine, daysAgo: [2, 1, 0]),
            importedSources
        ).map { workout, source in
            workout.sourceDevice = source
            return workout
        }

        #expect(evaluate(
            workouts: candidates,
            library: library,
            enrolledAt: day(-10)
        ) == .doNotOffer(.noQualifyingTarget))
    }

    @Test func excludesMesocyclesAndUnavailableRoutines() {
        let parent = RoutineFolderModel(userID: ForgeFitDemo.userID, name: "Block")
        let child = RoutineFolderModel(
            userID: ForgeFitDemo.userID,
            name: "Child",
            parentID: parent.id
        )
        let parentRoutine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Parent Routine",
            folderID: parent.id
        )
        let deletedChildRoutine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Deleted",
            folderID: child.id,
            deletedAt: now
        )

        let decision = MicrocycleTrackingDiscoveryPolicy.evaluate(
            workouts: workouts(for: parentRoutine, daysAgo: [2, 1, 0])
                + workouts(for: deletedChildRoutine, daysAgo: [2, 1, 0]),
            routines: [parentRoutine, deletedChildRoutine],
            folders: [parent, child],
            trackings: [],
            enrolledAt: day(-10),
            isSuppressed: false,
            now: now,
            calendar: calendar
        )

        #expect(decision == .doNotOffer(.noQualifyingTarget))
    }

    @Test func priorTrackingAndPermanentStateSuppressTheOffer() {
        let library = makeLibrary()
        let qualifying = workouts(for: library.routine, daysAgo: [2, 1, 0])
        let tracking = MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: library.folder.id,
            folderName: library.folder.name,
            anchorDate: now,
            durationDays: 7
        )

        #expect(evaluate(
            workouts: qualifying,
            library: library,
            trackings: [tracking],
            enrolledAt: day(-10)
        ) == .doNotOffer(.activeTracking))
        tracking.stateRaw = "ended"
        #expect(evaluate(
            workouts: qualifying,
            library: library,
            trackings: [tracking],
            enrolledAt: day(-10)
        ) == .doNotOffer(.alreadyUsed))
        #expect(evaluate(
            workouts: qualifying,
            library: library,
            enrolledAt: day(-10),
            isSuppressed: true
        ) == .doNotOffer(.suppressed))
    }

    @Test func deletedTrackingDoesNotSuppressAnOtherwiseEarnedOffer() throws {
        let library = makeLibrary()
        let tracking = MicrocycleTrackingModel(
            userID: ForgeFitDemo.userID,
            folderID: library.folder.id,
            folderName: library.folder.name,
            anchorDate: now,
            durationDays: 7,
            deletedAt: now
        )

        let decision = evaluate(
            workouts: workouts(for: library.routine, daysAgo: [2, 1, 0]),
            library: library,
            trackings: [tracking],
            enrolledAt: day(-10)
        )

        #expect(try #require(decision.offer).targetID == library.folder.id)
    }

    @Test func choosesFolderWhoseThirdWorkoutQualifiedMostRecently() throws {
        let older = makeLibrary(name: "Older")
        let newer = makeLibrary(name: "Newer")
        let decision = MicrocycleTrackingDiscoveryPolicy.evaluate(
            workouts: (
                workouts(for: older.routine, daysAgo: [8, 7, 6, 0])
                    + workouts(for: newer.routine, daysAgo: [5, 3, 1])
            ).sorted { $0.startedAt > $1.startedAt },
            routines: [older.routine, newer.routine],
            folders: [older.folder, newer.folder],
            trackings: [],
            enrolledAt: day(-10),
            isSuppressed: false,
            now: now,
            calendar: calendar
        )

        #expect(try #require(decision.offer).targetID == newer.folder.id)
    }

    @Test func duplicateCloudRowsForOneLogicalWorkoutCountOnce() {
        let library = makeLibrary()
        let duplicateID = UUID()
        let first = workouts(for: library.routine, daysAgo: [2])[0]
        let duplicate = WorkoutModel(
            id: duplicateID,
            userID: ForgeFitDemo.userID,
            routineID: library.routine.id,
            title: library.routine.name,
            startedAt: first.startedAt,
            endedAt: first.endedAt,
            sourceDevice: "iphone"
        )
        first.id = duplicateID

        let decision = evaluate(
            workouts: [first, duplicate] + workouts(for: library.routine, daysAgo: [1]),
            library: library,
            enrolledAt: day(-10)
        )

        #expect(decision == .doNotOffer(.noQualifyingTarget))
    }

    private func evaluate(
        workouts: [WorkoutModel],
        library: (folder: RoutineFolderModel, routine: RoutineModel),
        trackings: [MicrocycleTrackingModel] = [],
        enrolledAt: Date,
        isSuppressed: Bool = false
    ) -> FeatureDiscoveryDecision {
        MicrocycleTrackingDiscoveryPolicy.evaluate(
            workouts: workouts.sorted { $0.startedAt > $1.startedAt },
            routines: [library.routine],
            folders: [library.folder],
            trackings: trackings,
            enrolledAt: enrolledAt,
            isSuppressed: isSuppressed,
            now: now,
            calendar: calendar
        )
    }

    private func makeLibrary(
        name: String = "Cycle"
    ) -> (folder: RoutineFolderModel, routine: RoutineModel) {
        let folder = RoutineFolderModel(userID: ForgeFitDemo.userID, name: name)
        let routine = RoutineModel(
            userID: ForgeFitDemo.userID,
            name: "Routine",
            folderID: folder.id
        )
        return (folder, routine)
    }

    private func workouts(for routine: RoutineModel, daysAgo: [Int]) -> [WorkoutModel] {
        daysAgo.map { daysAgo in
            let end = day(-daysAgo).addingTimeInterval(12 * 3_600)
            return WorkoutModel(
                userID: ForgeFitDemo.userID,
                routineID: routine.id,
                title: routine.name,
                startedAt: end.addingTimeInterval(-3_600),
                endedAt: end,
                sourceDevice: "iphone"
            )
        }
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }
}

private extension FeatureDiscoveryDecision {
    var offer: FeatureDiscoveryOffer? {
        guard case .offer(let offer) = self else { return nil }
        return offer
    }
}
