import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct TrainingAnalyticsPresentationTests {
    private let userID = ForgeFitDemo.userID
    private let routineID = UUID(uuidString: "00000000-0000-7000-8000-00000000D001")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func routineDurationKeepsSecondsAndPresentsMinutes() throws {
        let workout = WorkoutModel(
            userID: userID,
            routineID: routineID,
            startedAt: start,
            endedAt: start.addingTimeInterval(1_314)
        )
        let analytics = TrainingAnalytics(workouts: [workout], exercises: [], now: start)

        let point = try #require(analytics.routineSeries(routineID: routineID, metric: .duration).first)

        #expect(point.value == 1_314)
        #expect(TrainingAnalytics.Metric.duration.routineFormatted(point.value) == "21.9 min")
        #expect(TrainingAnalytics.Metric.duration.routineAxisValue(point.value) == "21.9")
        #expect(TrainingAnalytics.Metric.duration.routineAxisLabel == "Time (min)")
    }

    @Test func weeklyDurationRetainsItsDistinctHoursContract() throws {
        let workout = WorkoutModel(
            userID: userID,
            routineID: routineID,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600)
        )
        let analytics = TrainingAnalytics(workouts: [workout], exercises: [], now: start)

        let point = try #require(
            analytics.weeklySeries(.duration, weeks: 1).first { $0.value > 0 }
        )

        #expect(point.value == 1)
        #expect(TrainingAnalytics.Metric.duration.weeklyFormatted(point.value) == "1 hour")
        #expect(TrainingAnalytics.Metric.duration.weeklyAxisValue(point.value) == "1")
        #expect(TrainingAnalytics.Metric.duration.weeklyAxisLabel == "Time (hours)")
    }

    @Test func repPresentationUsesTrustworthySingularAndPluralLabels() {
        #expect(TrainingAnalytics.Metric.reps.weeklyFormatted(1) == "1 rep")
        #expect(TrainingAnalytics.Metric.reps.weeklyFormatted(2) == "2 reps")
        #expect(TrainingAnalytics.Metric.reps.routineFormatted(1) == "1 rep")
        #expect(TrainingAnalytics.Metric.reps.routineFormatted(2) == "2 reps")
    }

    @Test func routineSeriesExcludesOtherRoutinesAndDeletedOrUnfinishedWorkouts() {
        let included = workout(routineID: routineID, offset: 0, duration: 1_500)
        let otherRoutine = workout(routineID: UUID(), offset: -86_400, duration: 2_000)
        let deleted = workout(routineID: routineID, offset: -172_800, duration: 3_000)
        deleted.deletedAt = start
        let unfinished = WorkoutModel(
            userID: userID,
            routineID: routineID,
            startedAt: start.addingTimeInterval(-259_200)
        )
        let analytics = TrainingAnalytics(
            workouts: [included, otherRoutine, deleted, unfinished],
            exercises: [],
            now: start
        )

        #expect(analytics.routineSeries(routineID: routineID, metric: .duration).map(\.value) == [1_500])
    }

    private func workout(routineID: UUID, offset: TimeInterval, duration: TimeInterval) -> WorkoutModel {
        let startedAt = start.addingTimeInterval(offset)
        return WorkoutModel(
            userID: userID,
            routineID: routineID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration)
        )
    }
}
