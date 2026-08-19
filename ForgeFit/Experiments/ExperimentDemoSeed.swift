#if DEBUG
import ForgeCore
import ForgeData
import Foundation
import SwiftData

/// Deterministic, launch-argument-only data for exercising the complete
/// Experiments UI in Simulator and XCUITest.
///
/// Launch with `--reset-store --seed-experiment-demo`. The fixture deliberately
/// uses ordinary workouts and local experiment rows so the UI and analysis run
/// through the same membership and comparison paths as user-created data.
@MainActor
enum ExperimentDemoSeed {
    private static let activeID = UUID(uuidString: "E1000000-0000-4000-8000-000000000001")!
    private static let interventionID = UUID(uuidString: "E1000000-0000-4000-8000-000000000002")!
    private static let baselineID = UUID(uuidString: "E1000000-0000-4000-8000-000000000003")!

    private static let baselineEnergyID = UUID(uuidString: "E2000000-0000-4000-8000-000000000001")!
    private static let interventionEnergyID = UUID(uuidString: "E2000000-0000-4000-8000-000000000002")!
    private static let baselineWeightID = UUID(uuidString: "E2000000-0000-4000-8000-000000000003")!
    private static let interventionWeightID = UUID(uuidString: "E2000000-0000-4000-8000-000000000004")!

    static func seed(in context: ModelContext, now: Date = .now) throws {
        let existing = try context.fetch(FetchDescriptor<ExperimentModel>())
        guard !existing.contains(where: { $0.id == activeID }) else { return }
        // This flag is for a clean simulator fixture. Never manufacture a
        // second active experiment over somebody's existing local data.
        guard !existing.contains(where: { $0.deletedAt == nil && $0.isActive }) else {
            return
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        func date(_ dayOffset: Int, hour: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(byAdding: .hour, value: hour, to: day) ?? day
        }

        let baselineStart = date(-140)
        let baselineEnd = date(-84)
        let interventionStart = baselineEnd
        let interventionEnd = date(-28)
        let activeStart = date(-14)
        let activeEnd = date(42)
        let timeZone = TimeZone.current.identifier

        let headlineJSON = encode(
            ExperimentHeadlineMetricOption.all
                .filter {
                    [
                        "strength.volume",
                        "strength.workingSets",
                        "cardio.duration",
                        "cardio.distance",
                        "yoga.duration",
                    ].contains($0.id)
                }
                .map(\.selection)
        )

        let baseline = ExperimentModel(
            id: baselineID,
            userID: ForgeFitDemo.userID,
            name: "Baseline Block",
            protocolDescription: "Train normally and record energy and body weight.",
            question: "What does a typical eight-week block look like?",
            startedAt: baselineStart,
            plannedEndAt: baselineEnd,
            endedAt: baselineEnd,
            timeZoneIdentifier: timeZone,
            state: .completed,
            headlineMetricSelectionsJSON: headlineJSON,
            resultsViewedAt: baselineEnd,
            createdAt: baselineStart,
            updatedAt: baselineEnd
        )
        let intervention = ExperimentModel(
            id: interventionID,
            userID: ForgeFitDemo.userID,
            name: "Creatine 5 g",
            protocolDescription: "Take 5 g with breakfast and keep the rest of training unchanged.",
            question: "How do my recorded training and recovery metrics differ from baseline?",
            startedAt: interventionStart,
            plannedEndAt: interventionEnd,
            endedAt: interventionEnd,
            timeZoneIdentifier: timeZone,
            state: .completed,
            headlineMetricSelectionsJSON: headlineJSON,
            createdAt: interventionStart,
            updatedAt: interventionEnd
        )
        let active = ExperimentModel(
            id: activeID,
            userID: ForgeFitDemo.userID,
            name: "Earlier Bedtime",
            protocolDescription: "Start winding down at 10:00 PM and aim to be in bed by 10:30 PM.",
            question: "What changes while I keep a more consistent bedtime?",
            startedAt: activeStart,
            plannedEndAt: activeEnd,
            timeZoneIdentifier: timeZone,
            state: .active,
            headlineMetricSelectionsJSON: headlineJSON,
            reminderEnabled: false,
            createdAt: activeStart,
            updatedAt: now
        )

        let baselineTrackers = [
            tracker(
                id: baselineEnergyID,
                experiment: baseline,
                label: "Morning energy",
                type: .rating,
                cadence: .daily,
                position: 0
            ),
            tracker(
                id: baselineWeightID,
                experiment: baseline,
                label: "Body weight",
                type: .number,
                unit: "kg",
                cadence: .selectedWeekdays,
                selectedWeekdays: [2, 5],
                position: 1
            ),
            tracker(
                experiment: baseline,
                label: "Training felt",
                type: .choice,
                options: ["Easy", "Expected", "Hard"],
                cadence: .perWorkout,
                position: 2
            ),
        ]
        let interventionTrackers = [
            tracker(
                id: interventionEnergyID,
                experiment: intervention,
                label: "Morning energy",
                type: .rating,
                cadence: .daily,
                position: 0
            ),
            tracker(
                id: interventionWeightID,
                experiment: intervention,
                label: "Body weight",
                type: .number,
                unit: "kg",
                cadence: .selectedWeekdays,
                selectedWeekdays: [2, 5],
                position: 1
            ),
            tracker(
                experiment: intervention,
                label: "Dose taken",
                type: .boolean,
                cadence: .daily,
                position: 2
            ),
            tracker(
                experiment: intervention,
                label: "Training felt",
                type: .choice,
                options: ["Easy", "Expected", "Hard"],
                cadence: .perWorkout,
                position: 3
            ),
            tracker(
                experiment: intervention,
                label: "Observation",
                type: .note,
                cadence: .anytime,
                position: 4
            ),
        ]
        let activeTrackers = [
            tracker(
                experiment: active,
                label: "In bed by 10:30",
                type: .boolean,
                cadence: .daily,
                position: 0
            ),
            tracker(
                experiment: active,
                label: "Morning energy",
                type: .rating,
                scaleMinimumLabel: "Drained",
                scaleMaximumLabel: "Excellent",
                cadence: .daily,
                position: 1
            ),
            tracker(
                experiment: active,
                label: "Pre-workout caffeine",
                type: .number,
                unit: "mg",
                cadence: .perWorkout,
                position: 2
            ),
            tracker(
                experiment: active,
                label: "Sleep note",
                type: .note,
                cadence: .anytime,
                position: 3
            ),
            tracker(
                experiment: active,
                label: "Evening screen time",
                type: .number,
                unit: "min",
                cadence: .daily,
                position: 4,
                archivedAt: date(-7)
            ),
        ]

        let comparison = ExperimentSavedComparison(
            reference: .experiment(
                id: baseline.id,
                start: baselineStart,
                end: baselineEnd,
                timeZoneIdentifier: timeZone
            ),
            customTrackerPairs: [
                interventionEnergyID: baselineEnergyID,
                interventionWeightID: baselineWeightID,
            ]
        )
        intervention.savedComparisonJSON = encode(comparison)

        [baseline, intervention, active].forEach(context.insert)
        (baselineTrackers + interventionTrackers + activeTrackers).forEach(context.insert)

        let exercises = try context.fetch(FetchDescriptor<ExerciseLibraryModel>())
        guard let strengthExercise = exercises.first(where: {
            $0.deletedAt == nil
                && !$0.isCardio
                && $0.name.localizedCaseInsensitiveContains("bench")
        }) ?? exercises.first(where: { $0.deletedAt == nil && !$0.isCardio }) else {
            throw DemoSeedError.missingExerciseLibrary
        }

        let baselineStrengthDates = [-133, -119, -105, -91]
        let interventionStrengthDates = [-77, -63, -49, -35]
        let activeStrengthDates = [-12, -8, -4, -1]
        let baselineWorkouts = baselineStrengthDates.enumerated().map { index, offset in
            strengthWorkout(
                at: date(offset, hour: 17),
                exerciseID: strengthExercise.id,
                load: 70 + Double(index) * 2.5,
                title: "Baseline Strength"
            )
        }
        let interventionWorkouts = interventionStrengthDates.enumerated().map { index, offset in
            strengthWorkout(
                at: date(offset, hour: 17),
                exerciseID: strengthExercise.id,
                load: 77.5 + Double(index) * 2.5,
                title: "Creatine Block Strength"
            )
        }
        let activeWorkouts = activeStrengthDates.enumerated().map { index, offset in
            strengthWorkout(
                at: date(offset, hour: 17),
                exerciseID: strengthExercise.id,
                load: 82.5 + Double(index) * 2.5,
                title: "Evening Strength"
            )
        }

        let cardioWorkouts = [
            cardioWorkout(at: date(-128, hour: 7), distance: 4_000, duration: 1_800),
            yogaWorkout(at: date(-100, hour: 18), duration: 1_500),
            cardioWorkout(at: date(-72, hour: 7), distance: 4_800, duration: 1_800),
            cardioWorkout(at: date(-44, hour: 7), distance: 5_100, duration: 1_800),
            yogaWorkout(at: date(-40, hour: 18), duration: 2_100),
            cardioWorkout(at: date(-10, hour: 7), distance: 5_200, duration: 1_780),
            yogaWorkout(at: date(-5, hour: 18), duration: 1_800),
        ]
        let allWorkouts = baselineWorkouts + interventionWorkouts + activeWorkouts + cardioWorkouts
        allWorkouts.forEach(context.insert)

        seedCompletedEntries(
            baseline: baseline,
            intervention: intervention,
            baselineTrackers: baselineTrackers,
            interventionTrackers: interventionTrackers,
            baselineWorkouts: baselineWorkouts,
            interventionWorkouts: interventionWorkouts,
            date: date,
            context: context
        )
        seedActiveEntries(
            experiment: active,
            trackers: activeTrackers,
            workouts: activeWorkouts,
            now: now,
            date: date,
            context: context
        )
        try context.save()
    }

    private static func tracker(
        id: UUID = UUID(),
        experiment: ExperimentModel,
        label: String,
        type: ExperimentTrackerType,
        unit: String? = nil,
        scaleMinimumLabel: String? = nil,
        scaleMaximumLabel: String? = nil,
        options: [String] = [],
        cadence: ExperimentTrackerCadence,
        selectedWeekdays: [Int] = [],
        position: Int,
        archivedAt: Date? = nil
    ) -> ExperimentTrackerModel {
        ExperimentTrackerModel(
            id: id,
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            label: label,
            type: type,
            unit: unit,
            scaleMinimumLabel: scaleMinimumLabel,
            scaleMaximumLabel: scaleMaximumLabel,
            options: options,
            cadence: cadence,
            selectedWeekdays: selectedWeekdays,
            position: position,
            createdAt: experiment.startedAt,
            updatedAt: archivedAt ?? experiment.updatedAt,
            archivedAt: archivedAt
        )
    }

    private static func strengthWorkout(
        at start: Date,
        exerciseID: UUID,
        load: Double,
        title: String
    ) -> WorkoutModel {
        let sets = (0..<3).map { position in
            SetModel(
                userID: ForgeFitDemo.userID,
                position: position,
                setType: .working,
                reps: 8,
                weight: load,
                rpe: 7.5 + Double(position) * 0.25,
                completedAt: start.addingTimeInterval(Double(position + 1) * 360),
                createdAt: start
            )
        }
        let row = WorkoutExerciseModel(
            userID: ForgeFitDemo.userID,
            exerciseID: exerciseID,
            sets: sets
        )
        let workout = WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: title,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            avgHR: 118,
            maxHR: 154,
            activeEnergyKcal: 310,
            wholeSessionRPE: 7.5,
            readinessAtStart: 78,
            createdAt: start,
            updatedAt: start.addingTimeInterval(3_600),
            exercises: [row]
        )
        workout.recomputeTotalVolume()
        return workout
    }

    private static func cardioWorkout(
        at start: Date,
        distance: Double,
        duration: Int
    ) -> WorkoutModel {
        let end = start.addingTimeInterval(Double(duration))
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: CardioKind.run.rawValue,
            startedAt: start,
            endedAt: end,
            sourceDevice: "iphone",
            durationSeconds: duration,
            distanceMeters: distance,
            distanceSource: .userEntered,
            activeEnergyKcal: 320,
            avgHR: 151,
            maxHR: 174,
            hrZoneSeconds: [120, 360, 720, 480, 120],
            totalSteps: Int(distance * 1.25),
            avgPaceSecondsPerKm: Double(duration) / (distance / 1_000),
            avgPowerWatts: 238,
            elevationGainMeters: 42,
            createdAt: start,
            updatedAt: end
        )
        return WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Outdoor Run",
            startedAt: start,
            endedAt: end,
            avgHR: session.avgHR,
            maxHR: session.maxHR,
            activeEnergyKcal: session.activeEnergyKcal,
            createdAt: start,
            updatedAt: end,
            cardioSessions: [session]
        )
    }

    private static func yogaWorkout(at start: Date, duration: Int) -> WorkoutModel {
        let end = start.addingTimeInterval(Double(duration))
        let session = CardioSessionModel(
            userID: ForgeFitDemo.userID,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            endedAt: end,
            sourceDevice: CardioSessionModel.yogaManualSource,
            durationSeconds: duration,
            activeEnergyKcal: 95,
            avgHR: 86,
            maxHR: 108,
            effort: 4,
            posesCompleted: 12,
            createdAt: start,
            updatedAt: end
        )
        return WorkoutModel(
            userID: ForgeFitDemo.userID,
            title: "Mobility Yoga",
            startedAt: start,
            endedAt: end,
            avgHR: session.avgHR,
            maxHR: session.maxHR,
            activeEnergyKcal: session.activeEnergyKcal,
            createdAt: start,
            updatedAt: end,
            cardioSessions: [session]
        )
    }

    private static func seedCompletedEntries(
        baseline: ExperimentModel,
        intervention: ExperimentModel,
        baselineTrackers: [ExperimentTrackerModel],
        interventionTrackers: [ExperimentTrackerModel],
        baselineWorkouts: [WorkoutModel],
        interventionWorkouts: [WorkoutModel],
        date: (Int, Int) -> Date,
        context: ModelContext
    ) {
        for (index, offset) in stride(from: -137, through: -88, by: 7).enumerated() {
            insertEntry(
                experiment: baseline,
                tracker: baselineTrackers[0],
                at: date(offset, 8),
                value: .rating(3 + (index % 2)),
                context: context
            )
            insertEntry(
                experiment: baseline,
                tracker: baselineTrackers[1],
                at: date(offset, 8),
                value: .number(82.4 + Double(index) * 0.05),
                context: context
            )
        }
        for (index, workout) in baselineWorkouts.enumerated() {
            insertEntry(
                experiment: baseline,
                tracker: baselineTrackers[2],
                at: workout.startedAt,
                workoutID: workout.id,
                value: .choice(index < 2 ? "Hard" : "Expected"),
                context: context
            )
        }

        for (index, offset) in stride(from: -81, through: -32, by: 7).enumerated() {
            insertEntry(
                experiment: intervention,
                tracker: interventionTrackers[0],
                at: date(offset, 8),
                value: .rating(4 + (index % 2)),
                context: context
            )
            insertEntry(
                experiment: intervention,
                tracker: interventionTrackers[1],
                at: date(offset, 8),
                value: .number(82.9 + Double(index) * 0.08),
                context: context
            )
            insertEntry(
                experiment: intervention,
                tracker: interventionTrackers[2],
                at: date(offset, 8),
                value: .boolean(index != 3),
                context: context
            )
        }
        for (index, workout) in interventionWorkouts.enumerated() {
            insertEntry(
                experiment: intervention,
                tracker: interventionTrackers[3],
                at: workout.startedAt,
                workoutID: workout.id,
                value: .choice(index == 0 ? "Expected" : "Easy"),
                context: context
            )
        }
        insertEntry(
            experiment: intervention,
            tracker: interventionTrackers[4],
            at: date(-52, 20),
            value: .note("Felt well hydrated and recovered between working sets."),
            context: context
        )
    }

    private static func seedActiveEntries(
        experiment: ExperimentModel,
        trackers: [ExperimentTrackerModel],
        workouts: [WorkoutModel],
        now: Date,
        date: (Int, Int) -> Date,
        context: ModelContext
    ) {
        for offset in -13 ... -1 {
            insertEntry(
                experiment: experiment,
                tracker: trackers[0],
                at: date(offset, 21),
                value: .boolean(offset != -6),
                context: context
            )
            insertEntry(
                experiment: experiment,
                tracker: trackers[1],
                at: date(offset, 8),
                value: .rating(min(5, 3 + ((offset + 13) / 5))),
                context: context
            )
        }
        // Complete one of today's daily prompts and leave the other visibly
        // due so both completed and pending states are exercised.
        insertEntry(
            experiment: experiment,
            tracker: trackers[0],
            at: now.addingTimeInterval(-900),
            value: .boolean(true),
            context: context
        )
        for (index, workout) in workouts.enumerated() {
            insertEntry(
                experiment: experiment,
                tracker: trackers[2],
                at: workout.startedAt,
                workoutID: workout.id,
                value: .number(index.isMultiple(of: 2) ? 100 : 150),
                context: context
            )
        }
        insertEntry(
            experiment: experiment,
            tracker: trackers[3],
            at: date(-3, 8),
            value: .note("Woke before the alarm and felt ready to train."),
            context: context
        )
        for offset in -13 ... -8 {
            insertEntry(
                experiment: experiment,
                tracker: trackers[4],
                at: date(offset, 21),
                value: .number(Double(70 + abs(offset))),
                context: context
            )
        }
    }

    private static func insertEntry(
        experiment: ExperimentModel,
        tracker: ExperimentTrackerModel,
        at observedAt: Date,
        workoutID: UUID? = nil,
        value: ExperimentEntryValue,
        context: ModelContext
    ) {
        context.insert(ExperimentEntryModel(
            userID: ForgeFitDemo.userID,
            experimentID: experiment.id,
            trackerID: tracker.id,
            workoutID: workoutID,
            observedAt: observedAt,
            value: value,
            definitionSnapshotJSON: snapshot(for: tracker),
            createdAt: observedAt,
            updatedAt: observedAt
        ))
    }

    private static func snapshot(for tracker: ExperimentTrackerModel) -> String {
        struct Snapshot: Encodable {
            let version: Int
            let label: String
            let type: ExperimentTrackerType
            let unit: String?
            let scaleMinimumLabel: String?
            let scaleMaximumLabel: String?
            let options: [String]
        }
        return encode(Snapshot(
            version: tracker.definitionVersion,
            label: tracker.label,
            type: tracker.type,
            unit: tracker.unit,
            scaleMinimumLabel: tracker.scaleMinimumLabel,
            scaleMaximumLabel: tracker.scaleMaximumLabel,
            options: tracker.options
        ))
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private enum DemoSeedError: Error {
        case missingExerciseLibrary
    }
}
#endif
