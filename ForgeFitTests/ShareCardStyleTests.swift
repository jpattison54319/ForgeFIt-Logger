import ForgeCore
import ForgeData
import Foundation
import SwiftData
import Testing
import UIKit
@testable import ForgeFit

/// The share carousel's shape detection, page availability, and the
/// training-log card's layout budget. These rules keep the four workout
/// shapes consistent across every card style — a drift here shows up as a
/// hollow or overflowing share image.
@MainActor
struct ShareCardStyleTests {
    private let userID = UUID()

    private func strengthExercise(
        sets: Int = 3,
        weight: Double = 100,
        exerciseID: UUID = UUID()
    ) -> WorkoutExerciseModel {
        let setModels = (0..<sets).map {
            SetModel(userID: userID, position: $0, reps: 8, weight: weight + Double($0), completedAt: .now)
        }
        return WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: setModels)
    }

    private func cardioSession(yoga: Bool = false, linkedTo exercise: WorkoutExerciseModel? = nil) -> CardioSessionModel {
        let session = CardioSessionModel(userID: userID, modality: yoga ? "yoga" : "run")
        session.workoutExerciseID = exercise?.id
        session.durationSeconds = 600
        return session
    }

    private func shape(of workout: WorkoutModel) -> WorkoutShareShape {
        let summary = TrainingAnalytics(workouts: [workout], exercises: []).summary(for: workout)
        return .of(workout: workout, summary: summary)
    }

    // MARK: - Shape detection

    @Test func shapesResolveForAllWorkoutKinds() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }

        let strength = WorkoutModel(userID: userID, exercises: [strengthExercise()])
        context.insert(strength)
        #expect(shape(of: strength) == .strength)

        let cardio = WorkoutModel(userID: userID, cardioSessions: [cardioSession()])
        context.insert(cardio)
        #expect(shape(of: cardio) == .cardio)

        let yoga = WorkoutModel(userID: userID, cardioSessions: [cardioSession(yoga: true)])
        context.insert(yoga)
        #expect(shape(of: yoga) == .yoga)

        let hybrid = WorkoutModel(userID: userID, exercises: [strengthExercise()], cardioSessions: [cardioSession()])
        context.insert(hybrid)
        #expect(shape(of: hybrid) == .hybrid)

        let conditioningMovementID = UUID()
        let conditioningPlan = ConditioningPlan(sections: [
            ConditioningSection(
                name: "21–15–9 Ladder",
                format: .ladder,
                scoreKind: .elapsedTime,
                repScheme: [21, 15, 9],
                movements: [ConditioningMovement(exerciseID: conditioningMovementID, targetValue: 21)]
            )
        ])
        let conditioning = WorkoutModel(
            userID: userID,
            conditioningPlanSnapshotJSON: conditioningPlan.encodedJSON(),
            // Legacy conditioning logs materialized movement totals as sets.
            // Their completed rows must not make set-recovery UI applicable.
            exercises: [strengthExercise(exerciseID: conditioningMovementID)]
        )
        context.insert(conditioning)
        let conditioningShape = shape(of: conditioning)
        #expect(conditioningShape == .conditioning)
        #expect(!conditioningShape.supportsBetweenSetRecovery)
        #expect(WorkoutShareShape.strength.supportsBetweenSetRecovery)
        #expect(WorkoutShareShape.hybrid.supportsBetweenSetRecovery)
        #expect(!WorkoutShareShape.cardio.supportsBetweenSetRecovery)
        #expect(!WorkoutShareShape.yoga.supportsBetweenSetRecovery)
    }

    @Test func legacyConditioningRowsCollapseIntoOneMixedTimelineBlock() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let movementIDs = (0..<4).map { _ in UUID() }
        let section = ConditioningSection(
            name: "100s Chipper",
            format: .forTime,
            scoreKind: .elapsedTime,
            rounds: 10,
            movements: movementIDs.map {
                ConditioningMovement(exerciseID: $0, targetValue: 10)
            }
        )
        let result = ConditioningResult(sectionResults: [
            ConditioningSectionResult(
                id: section.id,
                format: .forTime,
                scoreKind: .elapsedTime,
                elapsedSeconds: 720,
                fullRounds: 10,
                totalReps: 400,
                completed: true
            )
        ])
        let bench = strengthExercise(sets: 3, exerciseID: UUID())
        bench.position = 0
        let materialized = movementIDs.enumerated().map { index, exerciseID in
            WorkoutExerciseModel(
                userID: userID,
                exerciseID: exerciseID,
                position: index + 1,
                sets: (0..<10).map {
                    SetModel(userID: userID, position: $0, reps: 10, completedAt: .now)
                }
            )
        }
        let workout = WorkoutModel(
            userID: userID,
            endedAt: Date().addingTimeInterval(900),
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            conditioningResultJSON: result.encodedJSON(),
            exercises: [bench] + materialized
        )
        context.insert(workout)

        let presentation = WorkoutPresentationPlan.make(for: workout)
        #expect(presentation.items.count == 2)
        #expect(presentation.visibleExercises.map(\.id) == [bench.id])
        #expect(presentation.modalities == [.strength, .conditioning])
        #expect(presentation.isMixed)
        if case .legacyConditioning(let conditioning) = presentation.items[1] {
            #expect(conditioning.plan.sections.first?.rounds == 10)
            #expect(conditioning.result?.sectionResults.first?.totalReps == 400)
        } else {
            Issue.record("expected one conditioning block after the standalone lift")
        }

        let overview = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: [],
            durationSeconds: 900
        )
        #expect(overview.strengthSets == 3)
        #expect(overview.facts.map(\.label) == ["Total time", "Modalities", "Activities"])
        #expect(shape(of: workout) == .hybrid)

        let sharePlan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 14)
        let strengthBlocks = sharePlan.entries.compactMap { entry -> ShareTrainingLogPlan.StrengthBlock? in
            if case .strength(let block) = entry { return block }
            return nil
        }
        #expect(strengthBlocks.count == 1)
        #expect(strengthBlocks.first?.lines.count == 3)

        let theme = AppTheme.sageDark
        #expect(ShareRenderer.image(
            WorkoutShareCardTrainingLog(workout: workout, exercises: [], theme: theme),
            theme: theme
        )?.size == WorkoutShareCardTrainingLog.size)
        #expect(WorkoutShareRenderer.image(for: workout, exercises: [], theme: theme) != nil)
    }

    @Test func pureLegacyConditioningNeverBecomesStrengthHistory() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let movementID = UUID()
        let section = ConditioningSection(
            name: "Rounds",
            format: .forTime,
            rounds: 10,
            movements: [ConditioningMovement(exerciseID: movementID, targetValue: 10)]
        )
        let workout = WorkoutModel(
            userID: userID,
            conditioningPlanSnapshotJSON: ConditioningPlan(sections: [section]).encodedJSON(),
            exercises: [strengthExercise(sets: 10, exerciseID: movementID)]
        )
        context.insert(workout)

        let presentation = WorkoutPresentationPlan.make(for: workout)
        #expect(presentation.items.count == 1)
        #expect(presentation.modalities == [.conditioning])
        #expect(presentation.visibleExercises.isEmpty)
        #expect(shape(of: workout) == .conditioning)

        let overview = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: [],
            durationSeconds: 600
        )
        #expect(overview.strengthSets == 0)
        #expect(!overview.facts.map(\.label).contains("Sets"))
        #expect(!overview.facts.map(\.label).contains("Volume"))
    }

    @Test func planlessConditioningSessionRemainsVisibleAndCompleted() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let start = Date(timeIntervalSince1970: 1_780_050_000)
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.conditioningModality,
            startedAt: start,
            liveStartedAt: start,
            endedAt: start.addingTimeInterval(480),
            durationSeconds: 480,
            activeEnergyKcal: 120,
            avgHR: 154,
            maxHR: 178
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Garage Conditioning",
            startedAt: start,
            endedAt: start.addingTimeInterval(480),
            cardioSessions: [session]
        )
        context.insert(workout)

        let presentation = WorkoutPresentationPlan.make(for: workout)
        #expect(presentation.modalities == [.conditioning])
        #expect(presentation.items.count == 1)
        #expect(shape(of: workout) == .conditioning)

        let overview = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: [],
            durationSeconds: 480
        )
        #expect(overview.facts == [
            .init(label: "Duration", value: "8min"),
            .init(label: "Avg HR", value: "154"),
            .init(label: "Energy", value: "120 kcal")
        ])

        let theme = AppTheme.sageDark
        #expect(ShareRenderer.image(
            WorkoutShareCardTrainingLog(workout: workout, exercises: [], theme: theme),
            theme: theme
        )?.size == WorkoutShareCardTrainingLog.size)
        #expect(WorkoutShareRenderer.image(for: workout, exercises: [], theme: theme) != nil)
    }

    @Test func yogaHistoryFoldsLeftAndRightIntoOnePose() {
        let now = Date()
        let session = cardioSession(yoga: true)
        session.splits = [
            CardioSplitModel(
                userID: userID,
                cardioSessionID: session.id,
                index: 0,
                distanceMeters: 0,
                durationSeconds: 30,
                paceSecondsPerKm: 0,
                label: "Low Lunge — Left",
                startedAt: now,
                endedAt: now.addingTimeInterval(30)
            ),
            CardioSplitModel(
                userID: userID,
                cardioSessionID: session.id,
                index: 1,
                distanceMeters: 0,
                durationSeconds: 30,
                paceSecondsPerKm: 0,
                label: "Low Lunge — Right",
                startedAt: now.addingTimeInterval(30),
                endedAt: now.addingTimeInterval(60)
            )
        ]

        let poses = YogaHistoryPresentation.poses(session: session, plan: nil)
        #expect(poses.count == 1)
        #expect(poses.first?.name == "Low Lunge")
        #expect(poses.first?.durationSeconds == 60)
        #expect(poses.first?.sideDetail == "Both sides")
    }

    @Test func mixedConditioningAndYogaBlocksShareAsDistinctModalities() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let start = Date(timeIntervalSince1970: 1_780_100_000)

        let conditioningSection = ConditioningSection(
            name: "Template Name",
            format: .ladder,
            scoreKind: .elapsedTime,
            repScheme: [21, 15, 9],
            movements: [ConditioningMovement(exerciseID: UUID(), targetValue: 21)]
        )
        let conditioningResult = ConditioningResult(sectionResults: [
            ConditioningSectionResult(
                id: conditioningSection.id,
                format: .ladder,
                scoreKind: .elapsedTime,
                elapsedSeconds: 360,
                fullRounds: 3,
                totalReps: 45,
                completed: true
            )
        ])
        let conditioningBlock = WorkoutBlockModel(
            userID: userID,
            kind: .conditioning,
            position: 1,
            planSnapshotJSON: ConditioningPlan(sections: [conditioningSection]).encodedJSON(),
            resultJSON: conditioningResult.encodedJSON()
        )
        let conditioningSession = CardioSessionModel(
            userID: userID,
            workoutBlockID: conditioningBlock.id,
            modality: CardioSessionModel.conditioningModality,
            startedAt: start.addingTimeInterval(600),
            liveStartedAt: start.addingTimeInterval(600),
            endedAt: start.addingTimeInterval(960),
            durationSeconds: 360,
            activeEnergyKcal: 90,
            avgHR: 158,
            maxHR: 179
        )

        let yogaPlan = YogaFlowPlan(style: .yin, steps: [
            .init(poseID: UUID(), name: "Low Lunge", holdSeconds: 30, side: .bothSides)
        ])
        let yogaBlock = WorkoutBlockModel(
            userID: userID,
            kind: .yoga,
            position: 2,
            planSnapshotJSON: yogaPlan.encodedJSON()
        )
        let yogaSession = CardioSessionModel(
            userID: userID,
            workoutBlockID: yogaBlock.id,
            modality: CardioSessionModel.yogaModality,
            startedAt: start.addingTimeInterval(1_000),
            liveStartedAt: start.addingTimeInterval(1_000),
            endedAt: start.addingTimeInterval(1_060),
            durationSeconds: 60,
            activeEnergyKcal: 15,
            avgHR: 92,
            maxHR: 110,
            yogaStyleRaw: YogaStyle.yin.rawValue,
            posesCompleted: 2
        )
        yogaSession.splits = [
            CardioSplitModel(
                userID: userID,
                cardioSessionID: yogaSession.id,
                index: 0,
                distanceMeters: 0,
                durationSeconds: 30,
                paceSecondsPerKm: 0,
                label: "Low Lunge — Left",
                startedAt: start.addingTimeInterval(1_000),
                endedAt: start.addingTimeInterval(1_030)
            ),
            CardioSplitModel(
                userID: userID,
                cardioSessionID: yogaSession.id,
                index: 1,
                distanceMeters: 0,
                durationSeconds: 30,
                paceSecondsPerKm: 0,
                label: "Low Lunge — Right",
                startedAt: start.addingTimeInterval(1_030),
                endedAt: start.addingTimeInterval(1_060)
            )
        ]

        let lift = strengthExercise(sets: 3)
        lift.position = 0
        let workout = WorkoutModel(
            userID: userID,
            title: "My Mixed Session",
            startedAt: start,
            endedAt: start.addingTimeInterval(1_200),
            avgHR: 132,
            maxHR: 179,
            activeEnergyKcal: 300,
            exercises: [lift],
            cardioSessions: [conditioningSession, yogaSession],
            blocks: [conditioningBlock, yogaBlock]
        )
        context.insert(workout)

        let presentation = WorkoutPresentationPlan.make(for: workout)
        #expect(presentation.items.count == 3)
        #expect(presentation.modalities == [.strength, .conditioning, .yoga])
        #expect(shape(of: workout) == .hybrid)
        let overview = WorkoutOverviewPresentation.make(
            workout: workout,
            exercises: [],
            durationSeconds: 1_200
        )
        #expect(overview.facts == [
            .init(label: "Total time", value: "20min"),
            .init(label: "Modalities", value: "3"),
            .init(label: "Activities", value: "3")
        ])
        #expect(YogaHistoryPresentation.poseCount(session: yogaSession, plan: yogaPlan) == 1)

        let theme = AppTheme.sageDark
        #expect(ShareRenderer.image(
            WorkoutShareCardTrainingLog(workout: workout, exercises: [], theme: theme),
            theme: theme
        )?.size == WorkoutShareCardTrainingLog.size)
        #expect(ShareRenderer.image(
            WorkoutShareCardMinimal(workout: workout, exercises: [], theme: theme),
            theme: theme
        )?.size == WorkoutShareCardMinimal.size)
        #expect(WorkoutShareRenderer.image(for: workout, exercises: [], theme: theme) != nil)
    }

    @Test func elapsedConditioningFactsDoNotRepeatTheWorkoutTime() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let movementIDs = [UUID(), UUID()]
        let section = ConditioningSection(
            name: "21–15–9 Ladder",
            format: .ladder,
            scoreKind: .elapsedTime,
            repScheme: [21, 15, 9],
            movements: movementIDs.map { ConditioningMovement(exerciseID: $0, targetValue: 21) }
        )
        let plan = ConditioningPlan(sections: [section])
        let result = ConditioningResult(sectionResults: [
            ConditioningSectionResult(
                id: section.id,
                format: .ladder,
                scoreKind: .elapsedTime,
                elapsedSeconds: 300,
                fullRounds: 3,
                totalReps: 90,
                completed: true
            )
        ])
        let workout = WorkoutModel(
            userID: userID,
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_000_300),
            conditioningPlanSnapshotJSON: plan.encodedJSON(),
            conditioningResultJSON: result.encodedJSON()
        )
        context.insert(workout)

        let facts = ConditioningSharePresentation.workoutFacts(for: workout, durationSeconds: 300)
        #expect(facts.map(\.label) == ["Time", "Work", "Format"])
        #expect(facts.map(\.value) == ["5:00", "90 reps", "Descending ladder"])
        #expect(facts.filter { $0.value == "5:00" }.count == 1)

        let theme = AppTheme.sageDark
        #expect(ShareRenderer.image(
            WorkoutShareCardTrainingLog(workout: workout, exercises: [], theme: theme),
            theme: theme
        )?.size == WorkoutShareCardTrainingLog.size)
        #expect(ShareRenderer.image(
            WorkoutShareCardMinimal(workout: workout, exercises: [], theme: theme),
            theme: theme
        )?.size == WorkoutShareCardMinimal.size)
        #expect(WorkoutShareRenderer.image(for: workout, exercises: [], theme: theme) != nil)
    }

    @Test func incompleteConditioningSharesActualWorkAndHonestStatus() {
        let section = ConditioningSection(
            name: "Ten rounds",
            format: .forTime,
            rounds: 10,
            movements: [ConditioningMovement(exerciseID: UUID(), targetValue: 10)]
        )
        let result = ConditioningResult(sectionResults: [
            ConditioningSectionResult(
                id: section.id,
                format: .forTime,
                scoreKind: .elapsedTime,
                elapsedSeconds: 90,
                fullRounds: 0,
                totalReps: 0,
                completed: false
            )
        ])
        let context = ConditioningSharePresentation.Context(
            plan: ConditioningPlan(sections: [section]),
            result: result
        )

        #expect(ConditioningSharePresentation.completionStatus(for: context) == .incomplete)
        #expect(ConditioningSharePresentation.facts(for: context, durationSeconds: 90) == [
            .init(label: "Time", value: "1:30"),
            .init(label: "Status", value: "Incomplete"),
            .init(label: "Work", value: "0 reps")
        ])

        var capped = section
        capped.timeCapSeconds = 90
        #expect(ConditioningSharePresentation.completionStatus(
            section: capped,
            result: result.sectionResults[0]
        ) == .timeCap)
    }

    @Test func conditioningShareBlocksHidePresetNamesByDefault() {
        let section = ConditioningSection(
            name: "100s Chipper",
            format: .forTime,
            rounds: 10,
            movements: [ConditioningMovement(exerciseID: UUID(), targetValue: 10)]
        )
        let block = ConditioningShareBlock(
            plan: ConditioningPlan(sections: [section]),
            exercises: [],
            theme: .sageDark
        )

        #expect(!block.showsSectionName)
        #expect(ConditioningSharePresentation.prescription(section) == "10 rounds")
    }

    // MARK: - Page availability

    @Test func metricsPageOnlyExistsWithHeartRateData() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let workout = WorkoutModel(userID: userID, exercises: [strengthExercise()])
        context.insert(workout)
        let summary = TrainingAnalytics(workouts: [workout], exercises: []).summary(for: workout)

        let without = ShareCardStyle.available(workout: workout, summary: summary, hasHRSamples: false)
        #expect(!without.contains(.metrics))
        #expect(without == [.trainingLog, .minimal, .full])

        workout.hrZoneSeconds = [600, 300, 0, 0, 0]
        let withZones = ShareCardStyle.available(workout: workout, summary: summary, hasHRSamples: false)
        #expect(withZones.contains(.metrics))
    }

    // MARK: - Training-log budget

    @Test func smallSessionShowsEverySet() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let first = strengthExercise(sets: 3)
        first.position = 0
        let second = strengthExercise(sets: 4)
        second.position = 1
        let workout = WorkoutModel(userID: userID, exercises: [first, second])
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 14)
        let blocks = plan.entries.compactMap { entry -> ShareTrainingLogPlan.StrengthBlock? in
            if case .strength(let block) = entry { return block }
            return nil
        }
        #expect(blocks.count == 2)
        #expect(blocks.map(\.lines.count) == [3, 4])
        #expect(blocks.allSatisfy { $0.extraSets == 0 })
        #expect(plan.moreExercises == 0)
    }

    @Test func largeSessionCollapsesToTopSets() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        // 4 exercises × 6 sets = 24 completed sets — over any budget.
        let workout = WorkoutModel(userID: userID, exercises: (0..<4).map { _ in strengthExercise(sets: 6) })
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 14)
        let blocks = plan.entries.compactMap { entry -> ShareTrainingLogPlan.StrengthBlock? in
            if case .strength(let block) = entry { return block }
            return nil
        }
        #expect(blocks.allSatisfy { $0.lines.count == 1 })
        #expect(blocks.allSatisfy { $0.extraSets == 5 })
    }

    @Test func exercisesBeyondCapBecomeMoreCount() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        // Exactly maxExercises → all shown, no "+N more" line.
        let exact = WorkoutModel(
            userID: userID,
            exercises: (0..<ShareTrainingLogPlan.maxExercises).map { _ in strengthExercise(sets: 2) }
        )
        context.insert(exact)
        let exactPlan = ShareTrainingLogPlan.make(workout: exact, exercises: [], lineBudget: 14)
        #expect(exactPlan.entries.count == ShareTrainingLogPlan.maxExercises)
        #expect(exactPlan.moreExercises == 0)

        // Over-full → one entry is given up so the "+N more" line fits below.
        let overfull = WorkoutModel(userID: userID, exercises: (0..<8).map { _ in strengthExercise(sets: 2) })
        context.insert(overfull)
        let plan = ShareTrainingLogPlan.make(workout: overfull, exercises: [], lineBudget: 14)
        let strengthEntries = plan.entries.filter { if case .strength = $0 { return true } else { return false } }
        #expect(strengthEntries.count == ShareTrainingLogPlan.maxExercises - 1)
        #expect(plan.moreExercises == 4)
    }

    // MARK: - Render smoke test

    /// Rasterizes every card style for a hybrid workout with HR data — the
    /// worst-case layout (charts, zone bar, splits, GeometryReader bars all
    /// live). Catches render-time layout crashes the type checker can't.
    @Test func allCardStylesRenderToCorrectlySizedImages() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let lift = strengthExercise(sets: 4)
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        runExercise.position = 1
        let session = cardioSession(linkedTo: runExercise)
        session.liveStartedAt = Date(timeIntervalSince1970: 1_780_000_000)
        session.endedAt = Date(timeIntervalSince1970: 1_780_000_600)
        session.distanceMeters = 2000
        session.avgHR = 150
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        workout.endedAt = workout.startedAt.addingTimeInterval(2700)
        workout.hrZoneSeconds = [1000, 300, 200, 100, 0]
        workout.avgHR = 131
        workout.maxHR = 175
        workout.activeEnergyKcal = 400
        context.insert(workout)

        let theme = AppTheme.sageDark
        let samples = (0..<60).map { (date: workout.startedAt.addingTimeInterval(Double($0) * 45), bpm: 110 + ($0 % 40)) }

        let trainingLog = ShareRenderer.image(
            WorkoutShareCardTrainingLog(workout: workout, exercises: [], theme: theme), theme: theme
        )
        #expect(trainingLog?.size == WorkoutShareCardTrainingLog.size)

        let metrics = ShareRenderer.image(
            WorkoutShareCardMetrics(workout: workout, exercises: [], theme: theme, hrSamples: samples), theme: theme
        )
        #expect(metrics?.size == WorkoutShareCardMetrics.size)

        let minimal = ShareRenderer.image(
            WorkoutShareCardMinimal(workout: workout, exercises: [], theme: theme), theme: theme
        )
        #expect(minimal?.size == WorkoutShareCardMinimal.size)

        let full = WorkoutShareRenderer.image(for: workout, exercises: [], theme: theme, hrSamples: samples)
        #expect(full != nil)
        #expect(full?.size.width == 430)
    }

    @Test func hybridPlanKeepsCardioInPosition() throws {
        let (container, context) = try TestStore.make()
        defer { _ = container }
        let lift = strengthExercise(sets: 3)
        lift.position = 0
        let runExercise = WorkoutExerciseModel(userID: userID, exerciseID: UUID())
        runExercise.position = 1
        let session = cardioSession(linkedTo: runExercise)
        let workout = WorkoutModel(userID: userID, exercises: [lift, runExercise], cardioSessions: [session])
        context.insert(workout)

        let plan = ShareTrainingLogPlan.make(workout: workout, exercises: [], lineBudget: 12)
        #expect(plan.entries.count == 2)
        if case .cardio(let cardioEntry) = plan.entries[1] {
            #expect(cardioEntry.id == session.id)
        } else {
            Issue.record("expected the cardio session as the second entry")
        }
    }
}
