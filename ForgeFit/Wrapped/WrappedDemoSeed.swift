#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// DEBUG-only: seeds a realistic PREVIOUS month of training so the Wrapped
/// flow can be exercised end-to-end (launch with `--seed-wrapped-demo`).
/// Used by UI tests and manual design review — generation itself then runs
/// through the real launch path.
@MainActor
enum WrappedDemoSeed {
    static func run(in context: ModelContext) {
        let calendar = Calendar.current
        guard let monthStart = WrappedReportService.WrappedSchedule.dueMonthStart(now: Date(), calendar: calendar) else { return }
        // Idempotent: skip when last month already has data.
        let existing = (try? context.fetch(FetchDescriptor<WorkoutModel>())) ?? []
        let interval = calendar.dateInterval(of: .month, for: monthStart)
        if existing.contains(where: { workout in interval?.contains(workout.startedAt) == true }) { return }

        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let bench = exercises.first { $0.name.localizedCaseInsensitiveContains("bench press") && !$0.isCardio }
        let rowExercise = exercises.first { $0.name.localizedCaseInsensitiveContains("row") && !$0.isCardio }
        guard let bench else { return }
        let userID = ForgeFitDemo.userID

        func day(_ offset: Int, hour: Int = 17) -> Date {
            calendar.date(byAdding: .hour, value: hour, to: calendar.date(byAdding: .day, value: offset, to: monthStart)!)!
        }

        // 10 strength sessions alternating push/pull, progressively heavier,
        // second half slightly harder (RPE) with dipping readiness.
        for (index, offset) in [1, 3, 5, 8, 10, 12, 15, 17, 22, 26].enumerated() {
            let exercise = (index % 2 == 0 ? bench : (rowExercise ?? bench))
            let start = day(offset)
            let sets = (0..<4).map { position -> SetModel in
                let set = SetModel(
                    userID: userID,
                    position: position,
                    reps: 8,
                    weight: 60 + Double(index) * 1.5,
                    rpe: index < 5 ? 7.5 : 8.5,
                    completedAt: start.addingTimeInterval(Double(position + 1) * 240)
                )
                set.recomputeDerivedMetrics()
                return set
            }
            let we = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: sets)
            let workout = WorkoutModel(
                userID: userID,
                title: index % 2 == 0 ? "Push Day" : "Pull Day",
                startedAt: start,
                endedAt: start.addingTimeInterval(3_900),
                avgHR: 118 + index,
                maxHR: 158 + index,
                readinessAtStart: index < 5 ? 82 : 72,
                exercises: [we]
            )
            workout.recomputeTotalVolume()
            context.insert(workout)
        }

        // 5 runs, mostly hard (Z4-heavy) so the coaching engine has a story.
        for (index, offset) in [2, 9, 16, 20, 24].enumerated() {
            let start = day(offset, hour: 7)
            let minutes = 28 + index * 6
            let session = CardioSessionModel(userID: userID, modality: CardioKind.run.rawValue)
            session.startedAt = start
            session.endedAt = start.addingTimeInterval(Double(minutes) * 60)
            session.durationSeconds = minutes * 60
            session.distanceMeters = Double(minutes) * 165
            session.avgHR = 156
            session.maxHR = 176
            session.hrZoneSeconds = [60, 240, Int(Double(minutes) * 12), Int(Double(minutes) * 30), Int(Double(minutes) * 6)]
            let workout = WorkoutModel(
                userID: userID,
                title: "Morning Run",
                startedAt: start,
                endedAt: session.endedAt,
                avgHR: session.avgHR,
                maxHR: session.maxHR,
                cardioSessions: [session]
            )
            context.insert(workout)
        }
        try? context.save()
    }
}
#endif
