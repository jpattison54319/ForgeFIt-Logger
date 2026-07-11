import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
@testable import ForgeFit

@MainActor
struct RoutineDoseContextTests {
    private let userID = ForgeFitDemo.userID
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        return calendar.dateInterval(of: .weekOfYear, for: reference)!.start.addingTimeInterval(4 * 86_400 + 10 * 3_600)
    }

    @Test func normalYesterdayTrainingIsContextNotAnAutomaticReduction() {
        let chest = exercise("Bench Press", muscles: ["chest"])
        let routine = routine(chest: chest)
        let yesterday = workout(at: now.addingTimeInterval(-24 * 3_600), exercise: chest, sets: 4, rpe: 8)
        let report = RecoveryEngine(
            workouts: [yesterday],
            exercises: [chest],
            healthMetrics: readyRangeHealth(),
            calendar: calendar,
            now: now
        ).report()

        let context = RoutineDoseContext.make(
            routine: routine,
            workouts: [yesterday],
            exercises: [chest],
            recovery: report,
            calendar: calendar,
            now: now
        )

        #expect(context.muscles.contains { $0.muscle == "chest" })
        #expect(report.action == .trainAsPlanned)
        #expect(!context.needsLocalizedLighterVersion)
        #expect(CoachAdjustments.localizedPlan(for: context) == nil)
    }

    @Test func highLocalFatigueAndProjectedVolumeOfferAScopedLighterVersion() throws {
        let chest = exercise("Bench Press", muscles: ["chest"])
        let quads = exercise("Squat", muscles: ["quadriceps"])
        let routine = routine(chest: chest, quads: quads)
        let currentWeek = workout(at: now.addingTimeInterval(-2 * 3_600), exercise: chest, sets: 12, rpe: 10)
        let priorWeeks = (1...3).map { weeksAgo in
            workout(
                at: calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: now)!,
                exercise: chest,
                sets: 12,
                rpe: 8
            )
        }
        let history = priorWeeks + [currentWeek]
        let report = RecoveryEngine(workouts: history, exercises: [chest, quads], calendar: calendar, now: now).report()

        let dose = RoutineDoseContext.make(
            routine: routine,
            workouts: history,
            exercises: [chest, quads],
            recovery: report,
            calendar: calendar,
            now: now
        )
        let chestContext = try #require(dose.triggeredMuscles.first { $0.muscle == "chest" })
        #expect(chestContext.recoveryScore < 0.60)
        #expect(chestContext.projectedWeeklySets > chestContext.weeklyThreshold)
        #expect(dose.affectedExerciseIDs == Set([chest.id]))

        let schema = Schema(ForgeDataSchema.models)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        let modelContext = ModelContext(container)
        let started = startedWorkout(chest: chest, quads: quads)
        modelContext.insert(started)
        try modelContext.save()

        let plan = try #require(CoachAdjustments.localizedPlan(for: dose))
        CoachAdjustments.apply(plan, to: started, in: modelContext)

        #expect(started.exercises.first { $0.exerciseID == chest.id }?.sets.count == 3)
        #expect(started.exercises.first { $0.exerciseID == quads.id }?.sets.count == 4)
    }

    private func exercise(_ name: String, muscles: [String]) -> ExerciseLibraryModel {
        ExerciseLibraryModel(id: UUID(), name: name, movementPattern: nil, primaryMuscles: muscles, equipment: "barbell")
    }

    private func routine(chest: ExerciseLibraryModel, quads: ExerciseLibraryModel? = nil) -> RoutineModel {
        var entries = [RoutineExerciseModel(
            userID: userID,
            exerciseID: chest.id,
            position: 0,
            sets: plannedSets()
        )]
        if let quads {
            entries.append(RoutineExerciseModel(
                userID: userID,
                exerciseID: quads.id,
                position: 1,
                sets: plannedSets()
            ))
        }
        return RoutineModel(userID: userID, name: "Full Body", exercises: entries)
    }

    private func plannedSets() -> [RoutineSetModel] {
        (0..<4).map { position in
            RoutineSetModel(userID: userID, position: position, setType: .working, targetRepsLow: 8, targetRPE: 9)
        }
    }

    private func workout(at date: Date, exercise: ExerciseLibraryModel, sets: Int, rpe: Double) -> WorkoutModel {
        let logged = (0..<sets).map { position in
            SetModel(
                userID: userID,
                position: position,
                setType: .working,
                reps: 8,
                weight: 100,
                rpe: rpe,
                completedAt: date.addingTimeInterval(Double(position * 90))
            )
        }
        return WorkoutModel(
            userID: userID,
            title: exercise.name,
            startedAt: date,
            endedAt: date.addingTimeInterval(3_600),
            exercises: [WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: logged)]
        )
    }

    private func startedWorkout(chest: ExerciseLibraryModel, quads: ExerciseLibraryModel) -> WorkoutModel {
        WorkoutModel(
            userID: userID,
            exercises: [
                WorkoutExerciseModel(userID: userID, exerciseID: chest.id, sets: plannedSets().enumerated().map { index, target in
                    SetModel(userID: userID, position: index, setType: target.setType, reps: 8, weight: 100, rpe: 9)
                }),
                WorkoutExerciseModel(userID: userID, exerciseID: quads.id, sets: plannedSets().enumerated().map { index, target in
                    SetModel(userID: userID, position: index, setType: target.setType, reps: 8, weight: 100, rpe: 9)
                }),
            ]
        )
    }

    private func readyRangeHealth() -> [RecoveryEngine.DailyHealthMetric] {
        (0..<40).map { day in
            RecoveryEngine.DailyHealthMetric(
                date: now.addingTimeInterval(-Double(day) * 86_400),
                hrvSDNN: day == 0 ? 48 : 50,
                restingHR: 55,
                sleepTotalMinutes: 480
            )
        }
    }
}
