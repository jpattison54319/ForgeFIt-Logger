import Foundation
import Testing
import ForgeCore
import ForgeData
@testable import ForgeFit

/// The cardio exercise-detail contract: sessions resolve per exercise, the
/// trend metric follows the modality (never a rep-max), records gate to what
/// the equipment measures, and pace guards keep GPS blips off the chart.
@MainActor
struct CardioExerciseStatsTests {

    private let userID = UUID()
    private let exerciseID = UUID()

    private func workout(
        daysAgo: Int,
        exerciseID: UUID,
        session: (UUID) -> CardioSessionModel
    ) -> WorkoutModel {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let row = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID)
        return WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(3600),
            exercises: [row],
            cardioSessions: [session(row.id)]
        )
    }

    private func runSession(rowID: UUID?, meters: Double?, seconds: Int?, daysAgo: Int = 0, modality: CardioKind = .run) -> CardioSessionModel {
        let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return CardioSessionModel(
            userID: userID,
            workoutExerciseID: rowID,
            modality: modality.rawValue,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(seconds ?? 0)),
            durationSeconds: seconds,
            distanceMeters: meters
        )
    }

    // MARK: - Entry resolution

    @Test func entriesMatchThroughWorkoutExerciseID() {
        let mine = workout(daysAgo: 1, exerciseID: exerciseID) {
            self.runSession(rowID: $0, meters: 5000, seconds: 1500, daysAgo: 1)
        }
        let other = workout(daysAgo: 2, exerciseID: UUID()) {
            self.runSession(rowID: $0, meters: 8000, seconds: 2400, daysAgo: 2)
        }
        let entries = CardioExerciseStats.entries(for: exerciseID, in: [mine, other])
        #expect(entries.count == 1)
        #expect(entries.first?.durationSeconds == 1500)
    }

    @Test func legacySetBasedCardioFallsBackToSetDuration() {
        let start = Calendar.current.date(byAdding: .day, value: -3, to: Date())!
        let set = SetModel(userID: userID, position: 0, durationSeconds: 900)
        set.completedAt = start
        let row = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID, sets: [set])
        let legacy = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(900),
            exercises: [row]
        )
        let entries = CardioExerciseStats.entries(for: exerciseID, in: [legacy])
        #expect(entries.count == 1)
        #expect(entries.first?.session == nil)
        #expect(entries.first?.durationSeconds == 900)
    }

    // MARK: - Trend selection

    @Test func runTrendsPaceAndFallsBackToDuration() {
        let paced = [
            workout(daysAgo: 2, exerciseID: exerciseID) { self.runSession(rowID: $0, meters: 5000, seconds: 1500, daysAgo: 2) },
            workout(daysAgo: 1, exerciseID: exerciseID) { self.runSession(rowID: $0, meters: 5000, seconds: 1450, daysAgo: 1) },
        ]
        let pacedTrend = CardioExerciseStats.trend(
            for: .run,
            entries: CardioExerciseStats.entries(for: exerciseID, in: paced)
        )
        #expect(pacedTrend.metric == .pace)
        #expect(pacedTrend.points.count == 2)

        // Manual duration-only logs (no distance) still trend something.
        let durationOnly = [
            workout(daysAgo: 2, exerciseID: exerciseID) { self.runSession(rowID: $0, meters: nil, seconds: 1800, daysAgo: 2) },
            workout(daysAgo: 1, exerciseID: exerciseID) { self.runSession(rowID: $0, meters: nil, seconds: 2100, daysAgo: 1) },
        ]
        let fallback = CardioExerciseStats.trend(
            for: .run,
            entries: CardioExerciseStats.entries(for: exerciseID, in: durationOnly)
        )
        #expect(fallback.metric == .duration)
        #expect(fallback.points.count == 2)
    }

    @Test func rowerTrendsSplitNotPace() {
        let workouts = (1...2).map { day in
            workout(daysAgo: day, exerciseID: exerciseID) {
                self.runSession(rowID: $0, meters: 2000, seconds: 480, daysAgo: day, modality: .row)
            }
        }
        let trend = CardioExerciseStats.trend(
            for: .row,
            entries: CardioExerciseStats.entries(for: exerciseID, in: workouts)
        )
        #expect(trend.metric == .split500)
        // 2000 m in 480 s = 240 s/km = 120 s per 500 m.
        #expect(trend.points.allSatisfy { abs($0.value - 120) < 0.01 })
    }

    @Test func paceGuardRejectsGPSBlips() {
        // 50 m "run" must not produce a pace point or a fastest-pace record.
        let blip = workout(daysAgo: 1, exerciseID: exerciseID) {
            self.runSession(rowID: $0, meters: 50, seconds: 10, daysAgo: 1)
        }
        let entries = CardioExerciseStats.entries(for: exerciseID, in: [blip])
        #expect(CardioExerciseStats.series(.pace, entries: entries).isEmpty)
        let records = CardioExerciseStats.records(for: .run, entries: entries)
        #expect(!records.contains { $0.kind == .fastestPace })
    }

    // MARK: - Records gating

    @Test func recordsFollowModalityContract() {
        let runs = [
            workout(daysAgo: 2, exerciseID: exerciseID) { self.runSession(rowID: $0, meters: 5000, seconds: 1500, daysAgo: 2) },
            workout(daysAgo: 1, exerciseID: exerciseID) { self.runSession(rowID: $0, meters: 8000, seconds: 2600, daysAgo: 1) },
        ]
        let runRecords = CardioExerciseStats.records(
            for: .run,
            entries: CardioExerciseStats.entries(for: exerciseID, in: runs)
        )
        let kinds = Set(runRecords.map(\.kind))
        #expect(kinds.contains(.fastestPace))
        #expect(kinds.contains(.longestDistance))
        #expect(kinds.contains(.longestDuration))
        #expect(!kinds.contains(.bestSplit500))
        // Fastest pace is the 5 km at 5:00/km (300 s/km), not the 8 km.
        #expect(abs(runRecords.first { $0.kind == .fastestPace }!.value - 300) < 0.01)
        // Longest distance is the 8 km.
        #expect(runRecords.first { $0.kind == .longestDistance }!.value == 8000)
    }

    @Test func stairRecordsCountFloorsNotDistance() {
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let row = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID)
        let session = CardioSessionModel(
            userID: userID,
            workoutExerciseID: row.id,
            modality: CardioKind.stair.rawValue,
            startedAt: start,
            endedAt: start.addingTimeInterval(1200),
            durationSeconds: 1200,
            floorsClimbed: 60
        )
        let stair = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(1200),
            exercises: [row],
            cardioSessions: [session]
        )
        let records = CardioExerciseStats.records(
            for: .stair,
            entries: CardioExerciseStats.entries(for: exerciseID, in: [stair])
        )
        let kinds = Set(records.map(\.kind))
        #expect(kinds.contains(.mostFloors))
        #expect(kinds.contains(.longestDuration))
        #expect(!kinds.contains(.longestDistance))   // stair has no meaningful distance
        #expect(!kinds.contains(.fastestPace))
    }

    // MARK: - Summary vocabulary

    @Test func summarySpeaksTheModalityLanguage() {
        let runs = [workout(daysAgo: 1, exerciseID: exerciseID) {
            self.runSession(rowID: $0, meters: 5000, seconds: 1500, daysAgo: 1)
        }]
        let entry = CardioExerciseStats.entries(for: exerciseID, in: runs).first!
        let summary = CardioExerciseStats.summary(for: entry, kind: .run, distanceUnit: .km)
        #expect(summary.contains("25min"))
        #expect(summary.contains("5 km"))
        #expect(summary.contains("5:00 /km"))

        let rowEntry = CardioExerciseStats.entries(
            for: exerciseID,
            in: [workout(daysAgo: 1, exerciseID: exerciseID) {
                self.runSession(rowID: $0, meters: 2000, seconds: 480, daysAgo: 1, modality: .row)
            }]
        ).first!
        let rowSummary = CardioExerciseStats.summary(for: rowEntry, kind: .row, distanceUnit: .km)
        #expect(rowSummary.contains("/500m"))
        #expect(!rowSummary.contains("/km"))
    }

    // MARK: - Yoga

    @Test func yogaEntriesRecordsAndSummarySpeakMatVocabulary() {
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let row = WorkoutExerciseModel(userID: userID, exerciseID: exerciseID)
        // Imported yoga sessions carry nil workoutExerciseID — the yoga
        // fallback must still attribute them to the pose in the workout.
        let session = CardioSessionModel(
            userID: userID,
            workoutExerciseID: nil,
            modality: CardioSessionModel.yogaModality,
            startedAt: start,
            endedAt: start.addingTimeInterval(1920),
            durationSeconds: 1920,
            avgHR: 104,
            yogaStyleRaw: "vinyasa",
            posesCompleted: 12
        )
        let practice = WorkoutModel(
            userID: userID,
            startedAt: start,
            endedAt: start.addingTimeInterval(1920),
            exercises: [row],
            cardioSessions: [session]
        )

        let entries = CardioExerciseStats.entries(for: exerciseID, in: [practice], isYoga: true)
        #expect(entries.count == 1)
        // Without the yoga flag, a nil-row session must NOT match (cardio
        // imports with nil IDs would otherwise leak across exercises).
        #expect(CardioExerciseStats.entries(for: exerciseID, in: [practice]).isEmpty)

        let records = CardioExerciseStats.yogaRecords(entries: entries)
        let kinds = Set(records.map(\.kind))
        #expect(kinds == [.longestPractice, .mostPoses])
        #expect(records.first { $0.kind == .mostPoses }?.value == 12)

        let summary = CardioExerciseStats.yogaSummary(for: entries[0])
        #expect(summary.contains("32min"))
        #expect(summary.contains("12 poses"))
        #expect(summary.contains("Vinyasa"))
        #expect(summary.contains("104 bpm"))
    }

    @Test func deletedSessionsAndWorkoutsAreExcluded() {
        let deleted = workout(daysAgo: 1, exerciseID: exerciseID) {
            self.runSession(rowID: $0, meters: 5000, seconds: 1500, daysAgo: 1)
        }
        deleted.deletedAt = Date()
        let tombstoned = workout(daysAgo: 2, exerciseID: exerciseID) {
            self.runSession(rowID: $0, meters: 5000, seconds: 1500, daysAgo: 2)
        }
        tombstoned.cardioSessions.first?.deletedAt = Date()
        let entries = CardioExerciseStats.entries(for: exerciseID, in: [deleted, tombstoned])
        #expect(entries.isEmpty)
    }
}
