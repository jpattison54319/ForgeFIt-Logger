import ForgeCore
import ForgeData
import Foundation
import Testing
@testable import ForgeFit

@MainActor
struct ExperimentHealthSnapshotTests {
    @Test
    func includesOnlyCalendarDaysCompletelyInsideTheWindow() throws {
        let timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try #require(
            calendar.date(from: DateComponents(
                year: 2026, month: 3, day: 7, hour: 12
            ))
        )
        let end = try #require(
            calendar.date(from: DateComponents(
                year: 2026, month: 3, day: 10, hour: 12
            ))
        )
        let window = try ExperimentWindow(
            start: start,
            end: end,
            timeZoneIdentifier: timeZone.identifier
        )
        let rows = (7...10).map { day in
            DailyActivityMetric(
                date: calendar.date(from: DateComponents(
                    year: 2026, month: 3, day: day, hour: 8
                ))!,
                steps: Double(day * 1_000),
                exerciseMinutes: nil,
                activeEnergyKcal: nil
            )
        }

        let output = ExperimentHealthLoader.makeDays(
            window: window,
            recovery: [],
            activity: rows,
            bodyweight: []
        )

        #expect(output.count == 2)
        #expect(output.map(\.steps) == [8_000, 9_000])
        #expect(output.allSatisfy { window.contains($0.timestamp) })
    }

    @Test
    func combinesActivityAndBodyweightWithoutRequiringRecoveryRows() throws {
        let timeZone = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))
        )
        let end = try #require(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 3))
        )
        let window = try ExperimentWindow(
            start: start,
            end: end,
            timeZoneIdentifier: timeZone.identifier
        )
        let secondDay = try #require(
            calendar.date(from: DateComponents(
                year: 2026, month: 1, day: 2, hour: 9
            ))
        )

        let output = ExperimentHealthLoader.makeDays(
            window: window,
            recovery: [],
            activity: [
                DailyActivityMetric(
                    date: start,
                    steps: 7_500,
                    exerciseMinutes: 45,
                    activeEnergyKcal: 520
                ),
            ],
            bodyweight: [(date: secondDay, value: 82.4)]
        )

        #expect(output.count == 2)
        #expect(output[0].steps == 7_500)
        #expect(output[1].bodyWeightKilograms == 82.4)
    }

    @Test
    func adapterUsesInjectedExactWindowHealthInsteadOfTheRollingHomeCache() throws {
        let timeZone = try #require(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func date(_ day: Int, hour: Int = 0) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: 1, day: day, hour: hour
            )))
        }
        let experiment = ExperimentModel(
            userID: ForgeFitDemo.userID,
            name: "Long-window Health",
            startedAt: try date(3),
            plannedEndAt: try date(5),
            endedAt: try date(5),
            timeZoneIdentifier: timeZone.identifier,
            state: .completed
        )
        let snapshot = ExperimentHealthSnapshot(days: [
            .init(timestamp: try date(1, hour: 12), steps: 1_000),
            .init(timestamp: try date(2, hour: 12), steps: 2_000),
            .init(timestamp: try date(3, hour: 12), steps: 3_000),
            .init(timestamp: try date(4, hour: 12), steps: 5_000),
        ])

        let result = try ExperimentAnalysisAdapter.result(
            experiment: experiment,
            trackers: [],
            entries: [],
            workouts: [],
            exercises: [],
            healthSnapshot: snapshot,
            now: try date(6)
        )
        let steps = try #require(result.metrics.first {
            $0.selection.metricID == "health.steps" && $0.selection.scope == nil
        })

        #expect(steps.current.value == 4_000)
        #expect(steps.reference.value == 1_500)
        #expect(steps.current.coverage.populatedCompleteCalendarDays == 2)
    }
}
