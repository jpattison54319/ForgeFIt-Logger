import Foundation
import ForgeCore
import ForgeData
import Testing
@testable import ForgeFit

@MainActor
struct RecoveryScoresTests {
    private let userID = ForgeFitDemo.userID
    private let calendar = Calendar.current
    /// Fixed "now": some morning at 10:00 local time.
    private var now: Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000)).addingTimeInterval(10 * 3600)
    }

    // MARK: - Calendar-day regression (the "trained yesterday shows today" bug)

    @Test func workoutLastNightCountsAsYesterdayNotToday() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        // Trained yesterday at 20:00 — only 14 hours ago, but one calendar day.
        let trainedAt = calendar.startOfDay(for: now).addingTimeInterval(-4 * 3600)
        let workout = strengthWorkout(startedAt: trainedAt, exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()

        #expect(report.daysSinceLast == 1)
        #expect(report.muscleFreshness.first { $0.muscle == "chest" }?.daysAgo == 1)
        #expect(!report.reasonChips.contains { $0.text == "Trained today" })
        let chest = report.recovery.muscles.first { $0.muscle == "chest" }
        #expect(chest?.lastTrainedDaysAgo == 1)
    }

    // MARK: - Muscle freshness exposure model

    @Test func hardSessionYesterdayLeavesMusclePartiallyRecovered() throws {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 9)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()
        let chest = try #require(report.recovery.muscles.first { $0.muscle == "chest" })
        let score = try #require(chest.state.value)

        #expect(score > 0.55 && score < 0.9)
        #expect(chest.readyInHours == nil)
        #expect(chest.isProvisional)
    }

    @Test func muscleIsReadyAgainAfterThreeDays() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-72 * 3600), exercise: bench, sets: 8, rpe: 9)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()
        let score = report.recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 0

        #expect(score > 0.75)
    }

    @Test func trainingTodayScoresLowerThanTrainingYesterday() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let todayWorkout = strengthWorkout(startedAt: now.addingTimeInterval(-2 * 3600), exercise: bench, sets: 8, rpe: 9)
        let yesterdayWorkout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 9)

        let todayScore = RecoveryEngine(workouts: [todayWorkout], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 1
        let yesterdayScore = RecoveryEngine(workouts: [yesterdayWorkout], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 0

        #expect(todayScore < yesterdayScore)
    }

    @Test func rpeTenSessionRecoversSlowerThanRpeSix() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let reference = (1...6).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(4 + index * 7) * 86_400), exercise: bench, sets: 8, rpe: 8)
        }
        let grinder = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 10)
        let easy = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 8, rpe: 6)

        let grinderScore = RecoveryEngine(workouts: reference + [grinder], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 1
        let easyScore = RecoveryEngine(workouts: reference + [easy], exercises: [bench], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.state.value ?? 0

        #expect(grinderScore < easyScore)
        // The gap should be material, not cosmetic — RPE 10 recovery looks
        // genuinely different from RPE 6.
        #expect(easyScore - grinderScore > 0.01)
    }

    @Test func untrainedMuscleReportsNoDataInsteadOfAScore() throws {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()
        let quads = try #require(report.recovery.muscles.first { $0.muscle == "quadriceps" })

        #expect(quads.state.value == nil)
        #expect(quads.statusLabel == "No data")
    }

    @Test func largerLatWorkoutTodayIsLessFreshThanResidualChestExposure() throws {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let pullover = exercise(
            "Lat Pullover",
            muscles: ["lats"],
            secondaryMuscles: ["chest"]
        )
        let reference = (1...6).flatMap { index in
            let daysAgo = Double(7 + index * 7)
            return [
                strengthWorkout(
                    startedAt: now.addingTimeInterval(-daysAgo * 86_400),
                    exercise: bench,
                    sets: 8,
                    rpe: 8
                ),
                strengthWorkout(
                    startedAt: now.addingTimeInterval(-(daysAgo + 2) * 86_400),
                    exercise: pullover,
                    sets: 8,
                    rpe: 8
                ),
            ]
        }
        let pushDay = strengthWorkout(
            startedAt: now.addingTimeInterval(-49 * 3_600),
            exercise: bench,
            sets: 8,
            rpe: 8
        )
        let latDay = strengthWorkout(
            startedAt: now.addingTimeInterval(-2 * 3_600),
            exercise: pullover,
            sets: 10,
            rpe: 8
        )

        let report = RecoveryEngine(
            workouts: reference + [pushDay, latDay],
            exercises: [bench, pullover],
            now: now
        ).report()
        let chest = try #require(report.recovery.muscles.first { $0.muscle == "chest" })
        let lats = try #require(report.recovery.muscles.first { $0.muscle == "lats" })

        #expect(try #require(lats.recentExposure) > #require(chest.recentExposure))
        #expect(try #require(lats.state.value) < #require(chest.state.value))
        #expect(try #require(lats.referenceDose) > 0)
        #expect(try #require(chest.referenceDose) > 0)
        #expect(lats.methodID == "muscle_exposure_v3")
    }

    @Test func eachMuscleUsesItsOwnTypicalSessionDose() throws {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let pulldown = exercise("Lat Pulldown", muscles: ["lats"])
        let history = (1...7).flatMap { index in
            let age = Double(4 + index * 7) * 86_400
            return [
                strengthWorkout(startedAt: now.addingTimeInterval(-age), exercise: bench, sets: 4, rpe: 8),
                strengthWorkout(startedAt: now.addingTimeInterval(-(age + 3_600)), exercise: pulldown, sets: 12, rpe: 8),
            ]
        }

        let muscles = RecoveryEngine(
            workouts: history,
            exercises: [bench, pulldown],
            now: now
        ).report().recovery.muscles
        let chestReference = try #require(muscles.first { $0.muscle == "chest" }?.referenceDose)
        let latReference = try #require(muscles.first { $0.muscle == "lats" }?.referenceDose)

        #expect(latReference == chestReference * 3)
    }

    @Test func backParentCountsEachSetOnceWhileChildrenKeepExactExposure() throws {
        let row = exercise(
            "High Row",
            muscles: ["mid_back"],
            secondaryMuscles: ["lats"]
        )
        let workout = strengthWorkout(
            startedAt: now.addingTimeInterval(-2 * 3_600),
            exercise: row,
            sets: 6,
            rpe: 8
        )

        let muscles = RecoveryEngine(workouts: [workout], exercises: [row], now: now)
            .report().recovery.muscles
        let back = try #require(muscles.first { $0.muscle == "back" })
        let lats = try #require(muscles.first { $0.muscle == "lats" })
        let middleBack = try #require(muscles.first { $0.muscle == "middle back" })

        #expect(back.recentExposure == middleBack.recentExposure)
        #expect(try #require(lats.recentExposure) == #require(middleBack.recentExposure) * 0.5)
    }

    @Test func everyParentUsesStrongestRoleInsteadOfSummingChildRoles() throws {
        let hierarchyCases = [
            (parent: "back", primary: "middle back", secondary: "lats"),
            (parent: "chest", primary: "mid chest", secondary: "upper chest"),
            (parent: "shoulders", primary: "front delts", secondary: "rear delts"),
        ]

        for hierarchy in hierarchyCases {
            let primaryOnly = exercise(
                "Primary \(hierarchy.parent)",
                muscles: [hierarchy.primary]
            )
            let primaryAndSecondary = exercise(
                "Primary and secondary \(hierarchy.parent)",
                muscles: [hierarchy.primary],
                secondaryMuscles: [hierarchy.secondary]
            )
            let primaryOnlyWorkout = strengthWorkout(
                startedAt: now.addingTimeInterval(-2 * 3_600),
                exercise: primaryOnly,
                sets: 6,
                rpe: 8
            )
            let combinedWorkout = strengthWorkout(
                startedAt: now.addingTimeInterval(-2 * 3_600),
                exercise: primaryAndSecondary,
                sets: 6,
                rpe: 8
            )

            let primaryOnlyExposure = RecoveryEngine(
                workouts: [primaryOnlyWorkout],
                exercises: [primaryOnly],
                now: now
            ).report().recovery.muscles.first { $0.muscle == hierarchy.parent }?.recentExposure
            let combinedExposure = RecoveryEngine(
                workouts: [combinedWorkout],
                exercises: [primaryAndSecondary],
                now: now
            ).report().recovery.muscles.first { $0.muscle == hierarchy.parent }?.recentExposure

            #expect(try #require(combinedExposure) == #require(primaryOnlyExposure))
        }
    }

    @Test func freshnessIncludesBodyRegionsAndCoreChildren() throws {
        let crunch = exercise(
            "Cable Crunch",
            muscles: ["abs"],
            secondaryMuscles: ["obliques"]
        )
        let workout = strengthWorkout(
            startedAt: now.addingTimeInterval(-2 * 3_600),
            exercise: crunch,
            sets: 4,
            rpe: 8
        )

        let muscles = RecoveryEngine(workouts: [workout], exercises: [crunch], now: now)
            .report().recovery.muscles
        let expected = MuscleTaxonomy.freshnessGroups.flatMap { [$0.name] + $0.children }

        #expect(muscles.map(\.muscle) == expected)
        #expect(try #require(muscles.first { $0.muscle == "core" }?.recentExposure) > 0)
        #expect(try #require(muscles.first { $0.muscle == "abdominals" }?.recentExposure) > 0)
        #expect(try #require(muscles.first { $0.muscle == "obliques" }?.recentExposure) > 0)
    }

    @Test func complexSetsAndEffortChangeMuscleDose() throws {
        let chest = exercise("Chest Press", muscles: ["chest"])
        let easy = strengthWorkout(startedAt: now.addingTimeInterval(-2 * 3_600), exercise: chest, sets: 1, rpe: 6)
        let hardDrop = strengthWorkout(startedAt: now.addingTimeInterval(-2 * 3_600), exercise: chest, sets: 1, rpe: 10)
        hardDrop.exercises[0].sets[0].setType = .drop

        let easyDose = try #require(RecoveryEngine(workouts: [easy], exercises: [chest], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.recentExposure)
        let hardDropDose = try #require(RecoveryEngine(workouts: [hardDrop], exercises: [chest], now: now)
            .report().recovery.muscles.first { $0.muscle == "chest" }?.recentExposure)

        #expect(hardDropDose > easyDose)
    }

    // MARK: - Cardio freshness: unified cardiovascular load

    @Test func higherSessionRPELoadProducesLowerCardioFreshness() {
        let reference = (1...6).map { index in
            cardioWorkout(startedAt: now.addingTimeInterval(-Double(4 + index * 7) * 86_400), minutes: 45, cr10: 5)
        }
        let hard = cardioWorkout(startedAt: now.addingTimeInterval(-24 * 3600), minutes: 45, cr10: 9)
        let easy = cardioWorkout(startedAt: now.addingTimeInterval(-24 * 3600), minutes: 45, cr10: 3)

        let hardScore = RecoveryEngine(workouts: reference + [hard], now: now).report().recovery.cardio.state.value ?? 1
        let easyScore = RecoveryEngine(workouts: reference + [easy], now: now).report().recovery.cardio.state.value ?? 0

        #expect(hardScore < easyScore)
    }

    @Test func cardioScoreNeedsACardioSessionFirst() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let workout = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [workout], exercises: [bench], now: now).report()

        #expect(report.recovery.cardio.state.value == nil)
    }

    @Test func measuredCircuitStrengthContributesToCardioFreshness() throws {
        let squat = exercise("Circuit Squat", muscles: ["quadriceps"])
        let circuit = strengthWorkout(
            startedAt: now.addingTimeInterval(-3_600),
            exercise: squat,
            sets: 6,
            rpe: 8
        )
        circuit.hrZoneSeconds = [0, 600, 1_200, 0, 0]

        let cardio = RecoveryEngine(workouts: [circuit], exercises: [squat], now: now)
            .report().recovery.cardio

        #expect(try #require(cardio.state.value) < 0.6)
        #expect(cardio.evidence == .measuredHeartRate)
        #expect(cardio.methodID == "cardio_exposure_v3")
    }

    @Test func strengthRPEWithoutMeasuredHeartRateDoesNotInventCardioLoad() {
        let squat = exercise("Traditional Squat", muscles: ["quadriceps"])
        let strength = strengthWorkout(
            startedAt: now.addingTimeInterval(-3_600),
            exercise: squat,
            sets: 6,
            rpe: 9
        )
        strength.wholeSessionRPE = 9
        strength.avgHR = 160

        let cardio = RecoveryEngine(workouts: [strength], exercises: [squat], now: now)
            .report().recovery.cardio

        #expect(cardio.state.value == nil)
    }

    @Test func measuredConditioningSeriesContributesWithoutRPE() throws {
        let series = CardioSampleSeries(samples: (0...180).map {
            CardioSampleSeries.Sample(t: $0 * 10, hr: 150)
        })
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.conditioningModality,
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            durationSeconds: 1_800,
            hrZoneSeconds: [0, 0, 1_800, 0, 0],
            sampleSeriesJSON: series.encodedJSON()
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Conditioning",
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            cardioSessions: [session]
        )

        let cardio = RecoveryEngine(workouts: [workout], now: now).report().recovery.cardio

        #expect(abs(try #require(cardio.state.value) - 0.5) < 0.001)
        #expect(cardio.evidence == .measuredHeartRate)
    }

    @Test func conditioningUsesSelectiveRPEFallback() throws {
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.conditioningModality,
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            durationSeconds: 1_800,
            effort: 8
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Conditioning",
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            cardioSessions: [session]
        )

        let cardio = RecoveryEngine(workouts: [workout], now: now).report().recovery.cardio

        #expect(abs(try #require(cardio.state.value) - 0.5) < 0.001)
        #expect(cardio.evidence == .perceivedEffort)
    }

    @Test func measuredWholeWorkoutZonesTakePrecedenceOverSessionRPE() throws {
        let session = CardioSessionModel(
            userID: userID,
            modality: CardioSessionModel.conditioningModality,
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            durationSeconds: 1_800,
            effort: 10
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Conditioning",
            startedAt: now.addingTimeInterval(-1_800),
            endedAt: now,
            hrZoneSeconds: [0, 0, 1_800, 0, 0],
            cardioSessions: [session]
        )

        let cardio = RecoveryEngine(workouts: [workout], now: now).report().recovery.cardio

        #expect(abs(try #require(cardio.state.value) - 0.5) < 0.001)
        #expect(cardio.evidence == .measuredHeartRate)
    }

    // MARK: - Systemic score and data gating

    @Test func systemicScoreIsBuildingWithNoDataAtAll() {
        let report = RecoveryEngine(workouts: [], now: now).report()

        if case .building = report.recovery.systemic.state {
            // expected
        } else {
            Issue.record("Expected building state with no data")
        }
        // Every part should say what it needs.
        #expect(report.recovery.systemic.parts.allSatisfy { $0.state.value == nil })
    }

    @Test func lowSevenDayHRVAverageLowersSystemicScore() {
        let lowWeek = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 35)
        let normalWeek = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)

        let lowScore = RecoveryEngine(workouts: [], healthMetrics: lowWeek, now: now)
            .report().recovery.systemic.state.value ?? 1
        let normalScore = RecoveryEngine(workouts: [], healthMetrics: normalWeek, now: now)
            .report().recovery.systemic.state.value ?? 0

        #expect(lowScore < normalScore)
    }

    @Test func hrvPartRequiresBaselineBeforeScoring() {
        // Only 5 days of history: enough for a 7-day average, no baseline.
        let short = healthSeries(baselineDays: 5, baselineHRV: 50, lastSevenHRV: 50)
        let report = RecoveryEngine(workouts: [], healthMetrics: short, now: now).report()
        let hrvPart = report.recovery.systemic.parts.first { $0.name == "HRV" }

        #expect(hrvPart?.state.value == nil)
    }

    @Test func trainingLoadIsNotPartOfTheSystemicRecoveryScore() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let single = strengthWorkout(startedAt: now.addingTimeInterval(-24 * 3600), exercise: bench, sets: 4, rpe: 8)

        let report = RecoveryEngine(workouts: [single], exercises: [bench], now: now).report()
        #expect(!report.recovery.systemic.parts.contains { $0.name == "Load balance" })

        // Six weeks of steady training → the part becomes a real score.
        let history = (0..<12).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(2 + index * 3) * 86_400), exercise: bench, sets: 4, rpe: 8)
        }
        let seasoned = RecoveryEngine(workouts: history, exercises: [bench], now: now).report()
        #expect(!seasoned.recovery.systemic.parts.contains { $0.name == "Load balance" })
    }

    @Test func partialNightDoesNotScoreFragmentedOvernightBiometrics() throws {
        let history = (1...20).map { day in
            RecoveryEngine.DailyHealthMetric(
                date: now.addingTimeInterval(-Double(day) * 86_400),
                hrvSDNN: 60,
                restingHR: 58,
                sleepTotalMinutes: 480,
                nocturnalHRV: 65,
                sleepingHR: 52
            )
        }
        var partial = RecoveryEngine.DailyHealthMetric(
            date: now,
            hrvSDNN: 60,
            restingHR: 58,
            sleepTotalMinutes: 120,
            nocturnalHRV: 90,
            sleepingHR: 42
        )
        partial.integrityFlags.insert(SleepIntegrity.Flag.partialWear)

        let report = RecoveryEngine(workouts: [], healthMetrics: history + [partial], now: now).report()
        let hrv = try #require(report.recovery.daily.parts.first { $0.name == "HRV (today)" })
        let restingHR = try #require(report.recovery.daily.parts.first { $0.name == "Heart rate" })

        #expect(hrv.state.value == nil)
        #expect(hrv.valueText == "—")
        #expect(restingHR.valueText == "58 bpm")
        #expect(!report.recovery.daily.parts.contains { $0.name == "Sleeping HR" && $0.valueText == "42 bpm" })
    }

    // MARK: - Confidence reflects data completeness

    /// The reported bug: confidence read 100% even when a signal (sleep) was
    /// missing, because the old formula only graded the signals that were
    /// present. Missing sleep must now pull confidence below full.
    @Test func confidenceDropsWhenSleepIsMissing() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let history = (0..<12).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(2 + index * 3) * 86_400),
                            exercise: bench, sets: 5, rpe: 8)
        }
        let full = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)
        let noSleep = full.map { metric -> RecoveryEngine.DailyHealthMetric in
            var copy = metric
            copy.sleepTotalMinutes = nil
            return copy
        }

        let fullReport = RecoveryEngine(workouts: history, exercises: [bench], healthMetrics: full, now: now).report()
        let noSleepReport = RecoveryEngine(workouts: history, exercises: [bench], healthMetrics: noSleep, now: now).report()

        #expect(noSleepReport.confidence < 1)
        #expect(noSleepReport.confidence < fullReport.confidence)
    }

    @Test func confidenceIsHighWithCompleteData() {
        let bench = exercise("Bench Press", muscles: ["chest"])
        let history = (0..<12).map { index in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(2 + index * 3) * 86_400),
                            exercise: bench, sets: 5, rpe: 8)
        }
        let full = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)

        let report = RecoveryEngine(workouts: history, exercises: [bench], healthMetrics: full, now: now).report()
        #expect(report.confidence >= 0.85)
    }

    @Test func confidenceIsLowWithNoData() {
        let report = RecoveryEngine(workouts: [], now: now).report()
        #expect(report.confidence <= 0.2)
    }

    // MARK: - Score/action consistency (green ring must never say "Deload")

    @Test func actionAgreesWithTheDisplayedScore() {
        // Daily identical training plus a monster session today used to crush
        // the legacy composite, while healthy biometrics kept the displayed
        // systemic score green.
        let bench = exercise("Bench Press", muscles: ["chest"])
        var workouts = (1...28).map { day in
            strengthWorkout(startedAt: now.addingTimeInterval(-Double(day) * 86_400), exercise: bench, sets: 3, rpe: 7)
        }
        workouts.append(strengthWorkout(startedAt: now.addingTimeInterval(-2 * 3600), exercise: bench, sets: 12, rpe: 9))
        let health = healthSeries(baselineDays: 40, baselineHRV: 50, lastSevenHRV: 50)

        let report = RecoveryEngine(workouts: workouts, exercises: [bench], healthMetrics: health, now: now).report()

        // The displayed score is healthy…
        #expect((report.displayScore ?? 0) >= 0.55)
        // …so the headline action must not contradict it with a deload call.
        #expect(report.action != .deloadRecover)
    }

    @Test func recentLoadAloneCannotTriggerADeload() {
        // No biometrics and no baseline: session size is descriptive context,
        // not evidence that recovery is low.
        let spike = WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: now.addingTimeInterval(-3600),
            endedAt: now,
            cardioSessions: [
                CardioSessionModel(
                    userID: userID,
                    modality: "run",
                    startedAt: now.addingTimeInterval(-3600),
                    endedAt: now,
                    durationSeconds: 7_200,
                    effort: 9
                )
            ]
        )

        let report = RecoveryEngine(workouts: [spike], now: now).report()

        #expect(report.trainingLoad.state == .building)
        #expect(report.action != .deloadRecover)
    }

    // MARK: - Fixtures

    private func exercise(
        _ name: String,
        muscles: [String],
        secondaryMuscles: [String] = []
    ) -> ExerciseLibraryModel {
        ExerciseLibraryModel(
            id: UUID(),
            name: name,
            movementPattern: nil,
            primaryMuscles: muscles,
            secondaryMuscles: secondaryMuscles,
            equipment: "barbell"
        )
    }

    private func strengthWorkout(startedAt: Date, exercise: ExerciseLibraryModel, sets: Int, rpe: Double) -> WorkoutModel {
        let workoutSets = (0..<sets).map { position in
            SetModel(
                userID: userID,
                position: position,
                setType: .working,
                reps: 8,
                weight: 100,
                rpe: rpe,
                completedAt: startedAt.addingTimeInterval(Double(position) * 180)
            )
        }
        let we = WorkoutExerciseModel(userID: userID, exerciseID: exercise.id, sets: workoutSets)
        let workout = WorkoutModel(
            userID: userID,
            title: exercise.name,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3_600),
            exercises: [we]
        )
        workout.recomputeTotalVolume()
        return workout
    }

    private func cardioWorkout(startedAt: Date, minutes: Int, cr10: Double) -> WorkoutModel {
        let cardio = CardioSessionModel(
            userID: userID,
            modality: "run",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(minutes * 60)),
            durationSeconds: minutes * 60
        )
        let workout = WorkoutModel(
            userID: userID,
            title: "Run",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(Double(minutes * 60)),
            cardioSessions: [cardio]
        )
        workout.wholeSessionRPE = cr10
        return workout
    }

    /// `baselineDays` of history at `baselineHRV`, with the last 7 days
    /// (including today) at `lastSevenHRV`.
    private func healthSeries(baselineDays: Int, baselineHRV: Double, lastSevenHRV: Double) -> [RecoveryEngine.DailyHealthMetric] {
        (0..<baselineDays).map { day in
            RecoveryEngine.DailyHealthMetric(
                date: now.addingTimeInterval(-Double(day) * 86_400),
                hrvSDNN: day < 7 ? lastSevenHRV : baselineHRV,
                restingHR: 55,
                sleepTotalMinutes: 480
            )
        }
    }
}
