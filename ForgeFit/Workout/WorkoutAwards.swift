import ForgeCore
import ForgeData
import Foundation

/// One source of truth for post-workout, history, search, and share awards.
/// Conditioning compares an exact prescription; yoga records compare within
/// a style so longer restorative work is never ranked against a power class.
enum WorkoutAwards {
    struct Tracker {
        private struct ConditioningBaseline {
            var bestElapsedSeconds: Int?
            var bestScore: Double?
            var fastestRoundSeconds: Int?
            var bestLoad: Double?
        }

        private struct YogaBaseline {
            var longestDurationSeconds: Int?
            var mostPoses: Int?
        }

        private var conditioningBaselines: [String: ConditioningBaseline] = [:]
        private var yogaBaselines: [YogaStyle: YogaBaseline] = [:]
        private var yogaPracticeDays: Set<Date> = []
        private let calendar: Calendar

        init(calendar: Calendar = .current) {
            self.calendar = calendar
        }

        /// Evaluates against earlier workouts already absorbed by this tracker,
        /// then advances the baselines with this workout's completed work.
        mutating func awards(for workout: WorkoutModel) -> [WorkoutAward] {
            guard workout.deletedAt == nil else { return [] }
            var awards: [WorkoutAward] = []
            // Keep this workout's results separate until evaluation finishes.
            // Two matching sections in one session must both compare with the
            // earlier-workout baseline, never with one another.
            var conditioningUpdates = conditioningBaselines

            for activity in conditioningActivities(in: workout) where activity.result.completed {
                let baseline = conditioningBaselines[activity.key] ?? ConditioningBaseline()
                var updated = conditioningUpdates[activity.key] ?? baseline
                let result = activity.result

                if result.scoreKind == .elapsedTime,
                   let elapsed = result.elapsedSeconds,
                   elapsed > 0 {
                    if let prior = baseline.bestElapsedSeconds, elapsed < prior {
                        awards.append(.init(
                            id: "conditioning-\(activity.section.id)-best-time",
                            title: activity.title,
                            kind: .conditioningBestTime,
                            valueText: Fmt.elapsed(elapsed)
                        ))
                    }
                    updated.bestElapsedSeconds = min(updated.bestElapsedSeconds ?? elapsed, elapsed)
                }

                if let score = scoreMetric(result), score > 0 {
                    if let prior = baseline.bestScore, score > prior {
                        awards.append(.init(
                            id: "conditioning-\(activity.section.id)-best-score",
                            title: activity.title,
                            kind: .conditioningBestScore,
                            valueText: conditioningScoreValue(result)
                        ))
                    }
                    updated.bestScore = max(updated.bestScore ?? score, score)
                }

                let analysis = ConditioningPerformanceAnalysis(
                    section: activity.section,
                    result: result
                )
                if let fastest = analysis.fastestRoundSeconds, fastest > 0 {
                    if let prior = baseline.fastestRoundSeconds, fastest < prior {
                        awards.append(.init(
                            id: "conditioning-\(activity.section.id)-fastest-round",
                            title: activity.title,
                            kind: .conditioningFastestRound,
                            valueText: Fmt.elapsed(fastest)
                        ))
                    }
                    updated.fastestRoundSeconds = min(
                        updated.fastestRoundSeconds ?? fastest,
                        fastest
                    )
                }

                if result.scoreKind == .load, let load = result.load, load > 0 {
                    if let prior = baseline.bestLoad, load > prior {
                        awards.append(.init(
                            id: "conditioning-\(activity.section.id)-best-load",
                            title: activity.title,
                            kind: .conditioningBestLoad,
                            valueText: Fmt.loadUnit(load)
                        ))
                    }
                    updated.bestLoad = max(updated.bestLoad ?? load, load)
                }

                conditioningUpdates[activity.key] = updated
            }
            conditioningBaselines = conditioningUpdates

            let yoga = yogaActivities(in: workout)
            var yogaUpdates = yogaBaselines
            for activity in yoga {
                let baseline = yogaBaselines[activity.style] ?? YogaBaseline()
                var updated = yogaUpdates[activity.style] ?? baseline

                if activity.durationSeconds > 0 {
                    if let prior = baseline.longestDurationSeconds,
                       activity.durationSeconds > prior {
                        awards.append(.init(
                            id: "yoga-\(activity.session.id)-longest-practice",
                            title: "\(activity.style.title) Yoga",
                            kind: .yogaLongestPractice,
                            valueText: Fmt.durationShort(activity.durationSeconds)
                        ))
                    }
                    updated.longestDurationSeconds = max(
                        updated.longestDurationSeconds ?? activity.durationSeconds,
                        activity.durationSeconds
                    )
                }

                if activity.poseCount > 0 {
                    if let prior = baseline.mostPoses, activity.poseCount > prior {
                        awards.append(.init(
                            id: "yoga-\(activity.session.id)-most-poses",
                            title: "\(activity.style.title) Yoga",
                            kind: .yogaMostPoses,
                            valueText: "\(activity.poseCount) poses"
                        ))
                    }
                    updated.mostPoses = max(updated.mostPoses ?? activity.poseCount, activity.poseCount)
                }

                yogaUpdates[activity.style] = updated
            }
            yogaBaselines = yogaUpdates

            if yoga.contains(where: { $0.durationSeconds >= 60 }) {
                let practiceDay = calendar.startOfDay(for: workout.startedAt)
                if !yogaPracticeDays.contains(practiceDay) {
                    let streak = streakEnding(on: practiceDay)
                    if WorkoutAwards.streakMilestones.contains(streak) {
                        awards.append(.init(
                            id: "yoga-\(workout.id)-streak-\(streak)",
                            title: "Yoga practice",
                            kind: .yogaStreak,
                            valueText: "\(streak) days"
                        ))
                    }
                    yogaPracticeDays.insert(practiceDay)
                }
            }

            return awards
        }

        private func streakEnding(on day: Date) -> Int {
            var streak = 1
            var cursor = day
            while let previous = calendar.date(byAdding: .day, value: -1, to: cursor),
                  yogaPracticeDays.contains(previous) {
                streak += 1
                cursor = previous
            }
            return streak
        }
    }

    static func all(
        for workout: WorkoutModel,
        history: [WorkoutModel],
        exercises: [ExerciseLibraryModel],
        calendar: Calendar = .current
    ) -> [WorkoutAward] {
        modalityAwards(for: workout, history: history, calendar: calendar)
            + strengthAwards(for: workout, history: history, exercises: exercises)
    }

    static func modalityAwards(
        for workout: WorkoutModel,
        history: [WorkoutModel],
        calendar: Calendar = .current
    ) -> [WorkoutAward] {
        var tracker = Tracker(calendar: calendar)
        var seen = Set<UUID>()
        let prior = history
            .filter {
                $0.id != workout.id
                    && $0.endedAt != nil
                    && $0.deletedAt == nil
                    && $0.startedAt < workout.startedAt
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        for past in prior where seen.insert(past.id).inserted {
            _ = tracker.awards(for: past)
        }
        return tracker.awards(for: workout)
    }

    /// Evaluates the current workout against a value-only history projection.
    /// Historical decoding and relationship walks happen on the isolated live
    /// history worker; user-facing strings remain formatted on MainActor.
    static func modalityAwards(
        for workout: WorkoutModel,
        history: PostWorkoutModalityHistorySnapshot,
        calendar: Calendar = .current
    ) -> [WorkoutAward] {
        var awards: [WorkoutAward] = []
        for activity in conditioningActivities(in: workout) where activity.result.completed {
            guard let baseline = history.conditioningBaselines[activity.key] else { continue }
            let result = activity.result
            if result.scoreKind == .elapsedTime,
               let elapsed = result.elapsedSeconds,
               elapsed > 0,
               let prior = baseline.bestElapsedSeconds,
               elapsed < prior {
                awards.append(.init(
                    id: "conditioning-\(activity.section.id)-best-time",
                    title: activity.title,
                    kind: .conditioningBestTime,
                    valueText: Fmt.elapsed(elapsed)
                ))
            }
            if let score = scoreMetric(result), score > 0,
               let prior = baseline.bestScore, score > prior {
                awards.append(.init(
                    id: "conditioning-\(activity.section.id)-best-score",
                    title: activity.title,
                    kind: .conditioningBestScore,
                    valueText: conditioningScoreValue(result)
                ))
            }
            if let fastest = ConditioningPerformanceAnalysis(
                section: activity.section,
                result: result
            ).fastestRoundSeconds,
               fastest > 0,
               let prior = baseline.fastestRoundSeconds,
               fastest < prior {
                awards.append(.init(
                    id: "conditioning-\(activity.section.id)-fastest-round",
                    title: activity.title,
                    kind: .conditioningFastestRound,
                    valueText: Fmt.elapsed(fastest)
                ))
            }
            if result.scoreKind == .load,
               let load = result.load,
               load > 0,
               let prior = baseline.bestLoad,
               load > prior {
                awards.append(.init(
                    id: "conditioning-\(activity.section.id)-best-load",
                    title: activity.title,
                    kind: .conditioningBestLoad,
                    valueText: Fmt.loadUnit(load)
                ))
            }
        }

        let yoga = yogaActivities(in: workout)
        for activity in yoga {
            guard let baseline = history.yogaBaselines[activity.style] else { continue }
            if activity.durationSeconds > 0,
               let prior = baseline.longestDurationSeconds,
               activity.durationSeconds > prior {
                awards.append(.init(
                    id: "yoga-\(activity.session.id)-longest-practice",
                    title: "\(activity.style.title) Yoga",
                    kind: .yogaLongestPractice,
                    valueText: Fmt.durationShort(activity.durationSeconds)
                ))
            }
            if activity.poseCount > 0,
               let prior = baseline.mostPoses,
               activity.poseCount > prior {
                awards.append(.init(
                    id: "yoga-\(activity.session.id)-most-poses",
                    title: "\(activity.style.title) Yoga",
                    kind: .yogaMostPoses,
                    valueText: "\(activity.poseCount) poses"
                ))
            }
        }

        if yoga.contains(where: { $0.durationSeconds >= 60 }) {
            let practiceDay = calendar.startOfDay(for: workout.startedAt)
            if !history.yogaPracticeDays.contains(practiceDay) {
                var streak = 1
                var cursor = practiceDay
                while let previous = calendar.date(byAdding: .day, value: -1, to: cursor),
                      history.yogaPracticeDays.contains(previous) {
                    streak += 1
                    cursor = previous
                }
                if streakMilestones.contains(streak) {
                    awards.append(.init(
                        id: "yoga-\(workout.id)-streak-\(streak)",
                        title: "Yoga practice",
                        kind: .yogaStreak,
                        valueText: "\(streak) days"
                    ))
                }
            }
        }
        return awards
    }

    private static let streakMilestones: Set<Int> = [3, 7, 14, 30, 60, 100, 365]

    private struct ConditioningActivity {
        let key: String
        let title: String
        let section: ConditioningSection
        let result: ConditioningSectionResult
    }

    private struct YogaActivity {
        let session: CardioSessionModel
        let style: YogaStyle
        let durationSeconds: Int
        let poseCount: Int
    }

    private static func conditioningActivities(in workout: WorkoutModel) -> [ConditioningActivity] {
        ConditioningSharePresentation.contexts(for: workout).flatMap { context in
            let results = context.result?.sectionResults ?? []
            return context.plan.sections.enumerated().compactMap { index, section -> ConditioningActivity? in
                let indexedResult: ConditioningSectionResult? = results.indices.contains(index)
                    ? results[index]
                    : nil
                let result = results.first { $0.id == section.id } ?? indexedResult
                guard let result else { return nil }
                let title = section.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return ConditioningActivity(
                    key: ConditioningPrescriptionSignature.key(for: section),
                    title: title.isEmpty ? section.format.title : title,
                    section: section,
                    result: result
                )
            }
        }
    }

    private static func yogaActivities(in workout: WorkoutModel) -> [YogaActivity] {
        workout.cardioSessions.compactMap { session in
            guard session.deletedAt == nil,
                  session.endedAt != nil,
                  session.isYogaSession,
                  isYogaPractice(session, in: workout) else { return nil }
            let plan = yogaPlan(for: session, workout: workout)
            return YogaActivity(
                session: session,
                style: session.resolvedYogaStyle,
                durationSeconds: max(0, session.durationSeconds ?? 0),
                poseCount: YogaHistoryPresentation.poseCount(session: session, plan: plan)
            )
        }
    }

    private static func isYogaPractice(_ session: CardioSessionModel, in workout: WorkoutModel) -> Bool {
        if let blockID = session.workoutBlockID,
           let block = workout.blocks.first(where: { $0.id == blockID }) {
            return block.kind == .yoga
        }
        return session.sourceDevice?.contains("conditioning") != true
    }

    private static func yogaPlan(
        for session: CardioSessionModel,
        workout: WorkoutModel
    ) -> YogaFlowPlan? {
        if let blockID = session.workoutBlockID,
           let block = workout.blocks.first(where: { $0.id == blockID }) {
            return YogaFlowPlan.decode(from: block.planSnapshotJSON)
        }
        if let exerciseID = session.workoutExerciseID,
           let exercise = workout.exercises.first(where: { $0.id == exerciseID }) {
            return YogaFlowPlan.decode(from: exercise.yogaFlowJSON)
        }
        return nil
    }

    private static func scoreMetric(_ result: ConditioningSectionResult) -> Double? {
        switch result.scoreKind {
        case .elapsedTime, .load:
            nil
        case .roundsAndReps:
            result.totalReps.map(Double.init) ?? result.fullRounds.map(Double.init)
        case .totalReps:
            result.totalReps.map(Double.init)
        case .completedIntervals:
            (result.completedIntervals ?? result.fullRounds).map(Double.init)
        }
    }

    private static func conditioningScoreValue(_ result: ConditioningSectionResult) -> String {
        if result.scoreKind == .roundsAndReps,
           let rounds = result.fullRounds,
           let reps = result.totalReps {
            return "\(rounds) rounds · \(reps) reps"
        }
        return ConditioningSharePresentation.score(result)
    }

    private static func strengthAwards(
        for workout: WorkoutModel,
        history: [WorkoutModel],
        exercises: [ExerciseLibraryModel]
    ) -> [WorkoutAward] {
        let baselines = PersonalRecords.baselines(history: history, before: workout)
        return strengthAwards(for: workout, baselines: baselines, exercises: exercises)
    }

    /// Strength awards from an already-materialized historical baseline. The
    /// completion sheet uses this overload after its isolated history worker
    /// returns, so only the just-finished workout is inspected on MainActor.
    static func strengthAwards(
        for workout: WorkoutModel,
        baselines: [UUID: ExerciseRecordBaseline],
        exercises: [ExerciseLibraryModel]
    ) -> [WorkoutAward] {
        return workout.exercises.sorted { $0.position < $1.position }.flatMap { workoutExercise in
            let exercise = exercises.first { $0.id == workoutExercise.exerciseID }
            let unit = exercise?.effectiveWeightUnit ?? Fmt.unit
            return PersonalRecords.summaryAwards(
                for: workoutExercise,
                baseline: baselines[workoutExercise.exerciseID]
            ).map { kind, set in
                let awardKind: WorkoutAward.Kind = switch kind {
                case .heaviestWeight: .heaviestWeight
                case .bestSetVolume: .bestSetVolume
                case .best1RM: .bestEstimated1RM
                }
                return WorkoutAward(
                    id: "strength-\(workoutExercise.id)-\(kind.rawValue)",
                    title: exercise?.name ?? "Exercise",
                    kind: awardKind,
                    valueText: kind.valueText(for: set, unit: unit)
                )
            }
        }
    }
}
