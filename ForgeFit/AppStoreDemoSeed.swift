#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// `--seed-appstore-demo`: the marketing capture fixture.
///
/// The existing `--seed-history` fixture exists to give UI tests *volume* to
/// search and paginate; its sessions are deliberately synthetic ("Push Day
/// #120", two lifts each, a treadmill row with no distance). App Store
/// screenshots and preview videos need the opposite: a small number of screens
/// that each look like a real athlete's account.
///
/// So this seed builds the account instead of the corpus —
/// * the bundled **Push Pull Legs** and **Hybrid Engine** programs, imported
///   through the same `RoutineTemplateCatalog` path a user would tap, so the
///   routine library, microcycle card, and logger prefills are all genuine;
/// * ~18 weeks of history logged *against those same routines*, with loads
///   that climb on a real progression schedule, so PRs, e1RM trends, muscle
///   balance, and history search all have honest data behind them;
/// * modality-correct cardio (outdoor run with pace + zone seconds, rower
///   with a /500 m split, indoor ride with power/cadence) and vinyasa yoga,
///   so the cardio and flexibility surfaces aren't empty.
///
/// Weights are stored in kilograms (the app's storage unit) but authored as
/// round **pound** targets, because the capture runs with `-weightUnitRaw lb`
/// and round numbers read better on a product page than 102.06 kg does.
///
/// Idempotent per store, DEBUG-only, and never reachable from a user path.
enum AppStoreDemoSeed {

    // MARK: - Entry point

    @MainActor
    static func seed(in context: ModelContext) throws {
        let probeTitle = "Push Day"
        var probe = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.title == probeTitle })
        probe.fetchLimit = 1
        guard try context.fetch(probe).isEmpty else { return }

        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        importPrograms(exercises: exercises, in: context)
        try seedHistory(in: context)
    }

    /// `--discard-active-workouts`: a preview tour that starts a workout leaves
    /// one running, and the next capture has to open on a clean Home. This is
    /// the alternative to `--reset-store` for repeat runs — resetting the store
    /// re-arms the onboarding cover, which is fatal to a recording.
    @MainActor
    static func discardActiveWorkouts(in context: ModelContext) throws {
        let active = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.endedAt == nil })
        for workout in try context.fetch(active) {
            context.delete(workout)
        }
        try context.save()
    }

    /// `--seed-active-workout`: a Push Day that is 34 minutes in with the first
    /// exercise finished. A workout the capture *starts* would show "0s" and
    /// an empty volume total in the logger header; this one shows what the
    /// screen looks like in the middle of real training.
    @MainActor
    static func seedActiveWorkout(in context: ModelContext) throws {
        let alreadyActive = FetchDescriptor<WorkoutModel>(predicate: #Predicate { $0.endedAt == nil })
        guard try context.fetch(alreadyActive).isEmpty else { return }

        let routines = (try? context.fetch(FetchDescriptor<RoutineModel>())) ?? []
        guard let routine = routines
            .filter({ $0.deletedAt == nil && !$0.exercises.isEmpty })
            .sorted(by: { $0.position < $1.position })
            .first else { return }

        let exercises = (try? context.fetch(FetchDescriptor<ExerciseLibraryModel>())) ?? []
        let notes = (try? context.fetch(FetchDescriptor<UserExerciseNoteModel>())) ?? []
        let workout = WorkoutFactory.start(
            routine: routine,
            exercises: exercises,
            setupNotes: notes,
            in: context
        )
        let start = Date().addingTimeInterval(-34 * 60)
        workout.startedAt = start

        // Complete the opening exercise, and the first two sets of the second,
        // so the logger shows completed rows, a live row, and untouched rows.
        // Values are adopted from each exercise's last completed session —
        // the same numbers the row's "previous" ghost is already offering, so
        // the logged rows agree with the ghosts beside them.
        let history = (try? context.fetch(FetchDescriptor<WorkoutModel>(
            predicate: #Predicate { $0.endedAt != nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))) ?? []

        let ordered = workout.exercises.sorted { $0.position < $1.position }
        for (index, exercise) in ordered.prefix(2).enumerated() {
            let previous = history
                .lazy
                .compactMap { past in past.exercises.first { $0.exerciseID == exercise.exerciseID } }
                .first
            let previousSets = (previous?.sets ?? []).sorted { $0.position < $1.position }
            let sets = exercise.sets.sorted { $0.position < $1.position }
            let completedCount = index == 0 ? sets.count : 2
            for (setIndex, set) in sets.prefix(completedCount).enumerated() {
                let source = previousSets.indices.contains(setIndex) ? previousSets[setIndex] : previousSets.last
                set.weight = set.weight ?? source?.weight
                set.reps = set.reps ?? source?.reps
                set.weightModeRaw = source?.weightModeRaw ?? set.weightModeRaw
                set.bodyweightKg = set.bodyweightKg ?? source?.bodyweightKg
                set.rpe = min(9, 7.5 + Double(setIndex) * 0.5)
                set.completedAt = start.addingTimeInterval(Double(300 + index * 900 + setIndex * 180))
                set.recomputeDerivedMetrics()
            }
        }
        workout.recomputeTotalVolume()
        try context.save()
    }

    // MARK: - Routine library

    /// Imports the two bundled programs a hybrid athlete would actually run.
    /// Anything the starter-content path left behind (the one-exercise "Full
    /// Body A") is removed first so the library reads as a considered plan.
    @MainActor
    private static func importPrograms(exercises: [ExerciseLibraryModel], in context: ModelContext) {
        let starterID = ForgeFitDemo.starterRoutineID
        for routine in (try? context.fetch(
            FetchDescriptor<RoutineModel>(predicate: #Predicate { $0.id == starterID })
        )) ?? [] {
            context.delete(routine)
        }

        let templates = RoutineTemplateCatalog.validTemplates(
            from: RoutineTemplateCatalog.load(),
            exercises: exercises
        )
        let programs = RoutineTemplateCatalog.validPrograms(
            from: RoutineTemplateCatalog.loadPrograms(),
            templates: templates,
            exercises: exercises
        )
        for id in ["push-pull-legs", "hybrid-engine"] {
            guard let program = programs.first(where: { $0.id == id }) else { continue }
            RoutineTemplateCatalog.importProgram(program, templates: templates, in: context)
        }
        try? context.save()
    }

    // MARK: - History

    /// One authored lift: the catalog slug, the pound load it started at, and
    /// the pound step it takes each time the progression advances.
    private struct Lift {
        let slug: String
        let startLb: Double
        let stepLb: Double
        let repsLow: Int
        let repsHigh: Int
        let sets: Int
        var mode: WeightMode = .external

        init(
            _ slug: String,
            _ startLb: Double,
            step: Double,
            reps: ClosedRange<Int>,
            sets: Int = 3,
            mode: WeightMode = .external
        ) {
            self.slug = slug
            self.startLb = startLb
            self.stepLb = step
            self.repsLow = reps.lowerBound
            self.repsHigh = reps.upperBound
            self.sets = sets
            self.mode = mode
        }
    }

    private static let pushDay = (
        title: "Push Day",
        lifts: [
            Lift("Barbell_Bench_Press_-_Medium_Grip", 155, step: 5, reps: 5...8),
            Lift("Incline_Dumbbell_Press", 55, step: 2.5, reps: 8...10),
            Lift("Dumbbell_Shoulder_Press", 45, step: 2.5, reps: 8...12),
            Lift("Side_Lateral_Raise", 15, step: 1.25, reps: 12...15),
            Lift("Triceps_Pushdown_-_Rope_Attachment", 50, step: 5, reps: 10...15),
        ]
    )

    private static let pullDay = (
        title: "Pull Day",
        lifts: [
            Lift("Barbell_Deadlift", 275, step: 10, reps: 3...5),
            Lift("Pullups", 0, step: 0, reps: 6...10, mode: .bodyweight),
            Lift("Seated_Cable_Rows", 130, step: 5, reps: 8...12),
            Lift("One-Arm_Dumbbell_Row", 65, step: 2.5, reps: 10...12, sets: 2),
            Lift("Barbell_Curl", 65, step: 2.5, reps: 8...12),
        ]
    )

    private static let legsDay = (
        title: "Leg Day",
        lifts: [
            Lift("Barbell_Squat", 205, step: 10, reps: 5...8),
            Lift("Romanian_Deadlift", 155, step: 5, reps: 6...10),
            Lift("Leg_Press", 270, step: 15, reps: 10...12),
            Lift("Lying_Leg_Curls", 80, step: 5, reps: 10...12),
            Lift("Seated_Calf_Raise", 90, step: 5, reps: 12...15),
        ]
    )

    private static let sessionNotes = [
        "Belt on the top set. Bar speed still moving.",
        "Slept 8h — everything felt lighter than the numbers say.",
        "Left shoulder cranky on the incline; dropped to a neutral grip.",
        "Back-off week. Kept the reps, took 10% off the bar.",
        "New bar path cue: elbows under the wrists. Worth keeping.",
    ]

    /// 18 weeks × 6 sessions, ending yesterday, so "today" is still an open
    /// invitation to train rather than a day that's already been logged.
    @MainActor
    private static func seedHistory(in context: ModelContext) throws {
        let calendar = Calendar.current
        let userID = ForgeFitDemo.userID
        let today = calendar.startOfDay(for: Date())
        let weeks = 18

        for weekIndex in 0..<weeks {
            // weekIndex 0 = the oldest week; the last week ends yesterday.
            let weeksAgo = weeks - 1 - weekIndex
            // The progression advances every third week; the third week of
            // each block is a deliberate back-off, which is what makes the
            // e1RM trend look like training rather than a straight line.
            let block = weekIndex / 3
            // The most recent week must not be the deload, or the training-load
            // gauge opens the product page announcing a taper.
            let isBackOff = weekIndex % 3 == 1

            for (dayOffset, kind) in weekPlan {
                // dayOffset 1...6 lands on "N days before today", so the
                // trailing seven days hold exactly the same six sessions as
                // every prior week — the training-load gauge then reads near
                // baseline instead of inventing a taper that isn't there.
                // The seventh day of each cycle is the rest day.
                guard let day = calendar.date(
                    byAdding: .day,
                    value: -(weeksAgo * 7) - (7 - dayOffset),
                    to: today
                ), day < today else { continue }

                switch kind {
                case .strength(let session):
                    context.insert(strengthWorkout(
                        session,
                        on: day,
                        block: block,
                        isBackOff: isBackOff,
                        weekIndex: weekIndex,
                        userID: userID,
                        calendar: calendar
                    ))
                case .cardio(let plan):
                    context.insert(cardioWorkout(
                        plan,
                        on: day,
                        weekIndex: weekIndex,
                        userID: userID,
                        calendar: calendar
                    ))
                case .yoga:
                    context.insert(yogaWorkout(
                        on: day,
                        weekIndex: weekIndex,
                        userID: userID,
                        calendar: calendar
                    ))
                }
            }
        }
        try context.save()

        // Level and XP come from the real award pipeline rather than a hand-set
        // number, so the profile card can't claim a level the history doesn't
        // support. Awards are idempotent (they stamp `xpAwardedAt`).
        for workout in try context.fetch(FetchDescriptor<WorkoutModel>()) {
            _ = XPService.awardXPIfNeeded(for: workout, in: context)
        }
        try context.save()
    }

    private enum SessionKind {
        case strength((title: String, lifts: [Lift]))
        case cardio(CardioPlan)
        case yoga
    }

    /// Positions inside a rolling seven-day cycle; 6 is the most recent day of
    /// the cycle and 7 (absent) is the rest day.
    private static var weekPlan: [(Int, SessionKind)] {
        [
            (1, .cardio(.zone2Run)),
            (2, .strength(pushDay)),
            (3, .cardio(.rowIntervals)),
            (4, .strength(pullDay)),
            (5, .yoga),
            // Yesterday is a lifting day on purpose: the Insights and Profile
            // headline stats read "this week", and a week that opened with
            // only a yoga class would headline "0 lbs".
            (6, .strength(legsDay)),
        ]
    }

    // MARK: - Strength sessions

    @MainActor
    private static func strengthWorkout(
        _ session: (title: String, lifts: [Lift]),
        on day: Date,
        block: Int,
        isBackOff: Bool,
        weekIndex: Int,
        userID: UUID,
        calendar: Calendar
    ) -> WorkoutModel {
        let start = calendar.date(bySettingHour: 17, minute: 45, second: 0, of: day) ?? day
        var elapsed = 240.0

        let exercises: [WorkoutExerciseModel] = session.lifts.enumerated().map { position, lift in
            let progressed = lift.startLb + Double(block) * lift.stepLb
            let workingLb = isBackOff ? (progressed * 0.9 / 5).rounded() * 5 : progressed
            let sets: [SetModel] = (0..<lift.sets).map { setIndex in
                // Reps fall across the set as fatigue accumulates, RPE climbs.
                let reps = max(lift.repsLow, lift.repsHigh - setIndex)
                let rpe: Double? = isBackOff ? 6.5 : min(9.5, 7.5 + Double(setIndex) * 0.5)
                elapsed += 165
                return SetModel(
                    userID: userID,
                    position: setIndex,
                    setType: .working,
                    weightMode: lift.mode,
                    reps: lift.mode == .bodyweight ? reps + block : reps,
                    weight: lift.mode == .bodyweight ? nil : kg(workingLb),
                    rpe: rpe,
                    bodyweightKg: lift.mode == .bodyweight ? kg(183) : nil,
                    completedAt: start.addingTimeInterval(elapsed)
                )
            }
            elapsed += 150
            return WorkoutExerciseModel(
                userID: userID,
                exerciseID: ExerciseCatalog.deterministicID(for: lift.slug),
                position: position,
                sets: sets
            )
        }

        let workout = WorkoutModel(
            userID: userID,
            title: session.title,
            startedAt: start,
            endedAt: start.addingTimeInterval(elapsed + 300),
            notes: weekIndex % 4 == 1 ? sessionNotes[weekIndex % sessionNotes.count] : nil,
            avgHR: 118 + weekIndex % 7,
            maxHR: 158 + weekIndex % 9,
            activeEnergyKcal: 430 + Double(weekIndex % 5) * 18,
            hrZoneSeconds: [1_020, 1_460, 780, 240, 60],
            wholeSessionRPE: isBackOff ? 6 : 8,
            wholeSessionRPERatedAt: start.addingTimeInterval(elapsed + 300),
            readinessAtStart: 68 + (weekIndex * 3) % 24,
            exercises: exercises
        )
        workout.recomputeTotalVolume()
        return workout
    }

    // MARK: - Cardio sessions

    private enum CardioPlan {
        case zone2Run
        case rowIntervals

        var title: String {
            switch self {
            case .zone2Run: "Zone 2 Run"
            case .rowIntervals: "Row Intervals"
            }
        }

        var slug: String {
            switch self {
            case .zone2Run: "Trail_Running_Walking"
            case .rowIntervals: "Rowing_Stationary"
            }
        }

        var kind: CardioKind {
            switch self {
            case .zone2Run: .run
            case .rowIntervals: .row
            }
        }
    }

    @MainActor
    private static func cardioWorkout(
        _ plan: CardioPlan,
        on day: Date,
        weekIndex: Int,
        userID: UUID,
        calendar: Calendar
    ) -> WorkoutModel {
        let start = calendar.date(bySettingHour: 6, minute: 40, second: 0, of: day) ?? day
        let row = WorkoutExerciseModel(
            userID: userID,
            exerciseID: ExerciseCatalog.deterministicID(for: plan.slug),
            position: 0
        )

        let session: CardioSessionModel
        switch plan {
        case .zone2Run:
            // Distance creeps up and pace creeps down over the block — an
            // aerobic base actually improving, which is what the pace trend
            // and critical-pace surfaces are for.
            let meters = 7_000.0 + Double(weekIndex) * 180
            let paceSecPerKm = 348.0 - Double(weekIndex) * 1.8
            let duration = Int(meters / 1_000 * paceSecPerKm)
            session = CardioSessionModel(
                userID: userID,
                workoutExerciseID: row.id,
                modality: CardioKind.run.rawValue,
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(duration)),
                durationSeconds: duration,
                distanceMeters: meters,
                distanceSource: .userEntered,
                activeEnergyKcal: Double(duration) / 60 * 11.5,
                avgHR: 141 + weekIndex % 5,
                maxHR: 162 + weekIndex % 6,
                hrZoneSeconds: [180, Int(Double(duration) * 0.68), Int(Double(duration) * 0.22), 120, 0],
                avgPaceSecondsPerKm: paceSecPerKm,
                avgCadence: 172 + weekIndex % 4,
                elevationGainMeters: 64 + Double(weekIndex % 5) * 7
            )
        case .rowIntervals:
            let duration = 2_400
            let split = 121.0 - Double(weekIndex) * 0.35
            session = CardioSessionModel(
                userID: userID,
                workoutExerciseID: row.id,
                modality: CardioKind.row.rawValue,
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(duration)),
                durationSeconds: duration,
                distanceMeters: 500 * Double(duration) / split,
                distanceSource: .userEntered,
                activeEnergyKcal: 486,
                avgHR: 152 + weekIndex % 5,
                maxHR: 178 + weekIndex % 6,
                hrZoneSeconds: [120, 420, 900, 780, 180],
                split500mSeconds: split,
                strokeRate: 26 + weekIndex % 3,
                avgPowerWatts: 212 + Double(weekIndex) * 1.4
            )
        }

        return WorkoutModel(
            userID: userID,
            title: plan.title,
            startedAt: start,
            endedAt: session.endedAt,
            avgHR: session.avgHR,
            maxHR: session.maxHR,
            activeEnergyKcal: session.activeEnergyKcal,
            hrZoneSeconds: session.hrZoneSeconds,
            readinessAtStart: 72 + (weekIndex * 5) % 20,
            exercises: [row],
            cardioSessions: [session]
        )
    }

    // MARK: - Yoga

    @MainActor
    private static func yogaWorkout(
        on day: Date,
        weekIndex: Int,
        userID: UUID,
        calendar: Calendar
    ) -> WorkoutModel {
        let start = calendar.date(bySettingHour: 8, minute: 15, second: 0, of: day) ?? day
        let duration = 1_800 + (weekIndex % 3) * 300
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            endedAt: start.addingTimeInterval(Double(duration)),
            durationSeconds: duration,
            activeEnergyKcal: Double(duration) / 60 * 4.2,
            avgHR: 96 + weekIndex % 6,
            maxHR: 118 + weekIndex % 7,
            yogaStyleRaw: "vinyasa",
            posesCompleted: 22 + weekIndex % 5
        )
        return WorkoutModel(
            userID: userID,
            title: "Vinyasa Flow",
            startedAt: start,
            endedAt: session.endedAt,
            avgHR: session.avgHR,
            maxHR: session.maxHR,
            activeEnergyKcal: session.activeEnergyKcal,
            exercises: [],
            cardioSessions: [session]
        )
    }

    // MARK: - Units

    /// Authored pounds → stored kilograms. See the type comment: the capture
    /// runs in lb, so seeding round lb keeps the product page free of 102.06.
    private static func kg(_ pounds: Double) -> Double { pounds * 0.453_592_37 }
}
#endif
