import Foundation
import Testing
@testable import ForgeData

/// The user-facing export's pure layer: RFC-4180 escaping, locale-proof
/// numbers, exact headers, cycle-hierarchy flattening, and the rule that
/// health values can only enter the workouts CSV through their dedicated
/// appendix columns.
struct DataExportFormatTests {

    // MARK: - CSV writer

    @Test func escapingQuotesCommasAndNewlines() {
        #expect(CSVWriter.field("plain") == "plain")
        #expect(CSVWriter.field("a,b") == "\"a,b\"")
        #expect(CSVWriter.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVWriter.field("line\nbreak") == "\"line\nbreak\"")
        #expect(CSVWriter.row(["a", "b,c", "d"]) == "a,\"b,c\",d")
    }

    @Test func numbersAreLocaleProofAndTrimmed() {
        #expect(CSVWriter.number(1234.5) == "1234.5")
        #expect(CSVWriter.number(102.5) == "102.5")
        #expect(CSVWriter.number(100.0) == "100")
        #expect(CSVWriter.number(0.12345) == "0.1235")   // ≤4 dp, rounded
        #expect(CSVWriter.number(Double?.none) == "")
        #expect(!CSVWriter.number(1_000_000.5).contains(","))
    }

    // MARK: - Workouts CSV

    private func sampleWorkout() -> BackupWorkout {
        let runExerciseID = UUID()
        return BackupWorkout(
            id: UUID(),
            routineID: nil,
            title: "Push, \"Heavy\"",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000),
            endedAt: Date(timeIntervalSince1970: 1_780_002_700),
            sourceDevice: nil,
            notes: "felt strong, no pain",
            externalSource: nil,
            externalID: nil,
            importFingerprint: nil,
            importBatchID: nil,
            xpAwardedAmount: nil,
            xpAwardedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_002_700),
            deletedAt: nil,
            exercises: [
                BackupWorkoutExercise(
                    id: UUID(), exerciseID: UUID(), name: "Bench Press", position: 0,
                    supersetGroup: 1, notes: "elbow niggle", notePinned: false,
                    restSeconds: nil, microRestSeconds: nil, intervalPlanJSON: nil,
                    yogaFlowJSON: nil, sourceRoutineExerciseID: nil,
                    createdAt: Date(timeIntervalSince1970: 1_780_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                    sets: [
                        BackupSet(
                            id: UUID(), position: 0, setType: "warmup", weightMode: "external",
                            reps: 10, weightKg: 60, rpe: nil, rir: nil, durationSeconds: nil,
                            holdSeconds: nil, partialReps: nil, addedWeight: nil,
                            assistanceWeight: nil, isUnilateral: false, implementWeight: nil,
                            limbCount: 2, isEccentric: false, isPaused: false,
                            machineSettingsJSON: nil, sourceRoutineSetID: nil, miniRepsJSON: nil,
                            side2Reps: nil, side2MiniRepsJSON: nil, plannedMiniSetCount: nil,
                            plannedMiniRepsJSON: nil,
                            completedAt: Date(timeIntervalSince1970: 1_780_000_300),
                            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
                            updatedAt: Date(timeIntervalSince1970: 1_780_000_300)
                        ),
                        BackupSet(
                            id: UUID(), position: 1, setType: "myoRep", weightMode: "external",
                            reps: 8, weightKg: 102.5, rpe: 8.5, rir: 1, durationSeconds: nil,
                            holdSeconds: nil, partialReps: 2, addedWeight: nil,
                            assistanceWeight: nil, isUnilateral: false, implementWeight: nil,
                            limbCount: 2, isEccentric: false, isPaused: false,
                            machineSettingsJSON: nil, sourceRoutineSetID: nil, miniRepsJSON: nil,
                            side2Reps: nil, side2MiniRepsJSON: nil, plannedMiniSetCount: nil,
                            plannedMiniRepsJSON: nil,
                            completedAt: Date(timeIntervalSince1970: 1_780_000_600),
                            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
                            updatedAt: Date(timeIntervalSince1970: 1_780_000_600)
                        ),
                    ]
                ),
                BackupWorkoutExercise(
                    id: runExerciseID, exerciseID: UUID(), name: "Treadmill Run", position: 1,
                    supersetGroup: nil, notes: nil, notePinned: false,
                    restSeconds: nil, microRestSeconds: nil, intervalPlanJSON: nil,
                    yogaFlowJSON: nil, sourceRoutineExerciseID: nil,
                    createdAt: Date(timeIntervalSince1970: 1_780_000_000),
                    updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
                    sets: []
                ),
            ],
            cardioSessions: [
                BackupCardioSession(
                    id: UUID(), workoutExerciseID: runExerciseID, modality: "run",
                    startedAt: Date(timeIntervalSince1970: 1_780_001_800), liveStartedAt: nil,
                    endedAt: Date(timeIntervalSince1970: 1_780_002_400), sourceDevice: nil,
                    durationSeconds: 600, distanceMeters: 1930, effort: 7,
                    avgPaceSecondsPerKm: 311, split500mSeconds: nil, strokeRate: nil,
                    avgPowerWatts: nil, avgCadence: nil, resistanceLevel: nil,
                    inclinePercent: nil, elevationGainMeters: 12, intervalsAutoApplied: false,
                    yogaStyleRaw: nil, posesCompleted: nil,
                    createdAt: Date(timeIntervalSince1970: 1_780_001_800),
                    updatedAt: Date(timeIntervalSince1970: 1_780_002_400),
                    deletedAt: nil, splits: [], routePoints: []
                ),
            ]
        )
    }

    @Test func workoutsCSVCarriesEveryEntryWithWorkoutColumnsRepeated() throws {
        let workout = sampleWorkout()
        let health = ExportHealthMetrics(
            workouts: [workout.id.uuidString: ExportWorkoutHealth(avgHR: 131, maxHR: 175, activeEnergyKcal: 401, readinessAtStart: 75)],
            cardioSessions: [workout.cardioSessions[0].id.uuidString: ExportCardioSessionHealth(avgHR: 162, maxHR: 171, activeEnergyKcal: 96)]
        )
        let csv = WorkoutCSVExport.csv(workouts: [workout], health: health)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(String(lines[0]) == WorkoutCSVExport.header.joined(separator: ","))
        // 2 sets + 1 cardio session + header + trailing newline artifact.
        #expect(lines.count == 5)

        let fields = parse(String(lines[2]))   // the myoRep set row
        #expect(fields.count == WorkoutCSVExport.header.count)
        #expect(fields[1] == "Push, \"Heavy\"")
        #expect(fields[4] == "felt strong, no pain")
        #expect(fields[5] == "131")
        #expect(fields[9] == "set")
        #expect(fields[15] == "myoRep")        // raw ForgeFit vocabulary
        #expect(fields[16] == "102.5")

        let cardio = parse(String(lines[3]))
        #expect(cardio[9] == "cardio")
        #expect(cardio[10] == "Treadmill Run") // anchor exercise name
        #expect(cardio[29] == "run")
        #expect(cardio[30] == "1930")
        #expect(cardio[37] == "162")           // cardio_avg_hr from appendix
    }

    @Test func healthColumnsEmptyWithoutAppendixEntry() {
        let workout = sampleWorkout()
        let csv = WorkoutCSVExport.csv(workouts: [workout], health: ExportHealthMetrics())
        let firstRow = parse(String(csv.split(separator: "\n")[1]))
        #expect(firstRow[5].isEmpty && firstRow[6].isEmpty && firstRow[7].isEmpty && firstRow[8].isEmpty)
    }

    // MARK: - Routines CSV

    @Test func cycleHierarchyFlattensAllThreeCases() {
        let macro = ExportRoutineFolder(id: UUID(), name: "Hypertrophy Block", position: 0)
        let meso = ExportRoutineFolder(id: UUID(), name: "Week 1-4", position: 0, parentID: macro.id)
        let byID = [macro.id: macro, meso.id: meso]

        #expect(RoutineCSVExport.cycleNames(folderID: meso.id, foldersByID: byID) == ("Hypertrophy Block", "Week 1-4"))
        #expect(RoutineCSVExport.cycleNames(folderID: macro.id, foldersByID: byID) == ("Hypertrophy Block", ""))
        #expect(RoutineCSVExport.cycleNames(folderID: nil, foldersByID: byID) == ("", ""))
    }

    @Test func routinesCSVKeepsEmptyRoutinesAndTargets() throws {
        let macro = ExportRoutineFolder(id: UUID(), name: "Base", position: 0)
        let meso = ExportRoutineFolder(id: UUID(), name: "Meso A", position: 0, parentID: macro.id)
        let library = ExportRoutineLibrary(
            folders: [macro, meso],
            routines: [
                ExportRoutine(
                    id: UUID(), name: "Push Day", folderID: meso.id, position: 0,
                    exercises: [
                        ExportRoutineExercise(
                            id: UUID(), exerciseID: UUID(), name: "Bench Press", position: 0,
                            supersetGroup: 0,
                            sets: [ExportRoutineSet(
                                position: 0, setType: "working",
                                targetRepsLow: 8, targetRepsHigh: 12, targetWeightKg: 100,
                                targetRPE: 8, plannedMiniReps: [12, 10, 8]
                            )]
                        ),
                    ]
                ),
                ExportRoutine(id: UUID(), name: "Sketch", notes: "ideas only", folderID: nil, position: 1),
            ]
        )
        let csv = RoutineCSVExport.csv(library: library)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(String(lines[0]) == RoutineCSVExport.header.joined(separator: ","))
        let setRow = parse(String(lines[1]))
        #expect(setRow[0] == "Base")
        #expect(setRow[1] == "Meso A")
        #expect(setRow[2] == "Push Day")
        #expect(setRow[12] == "8" && setRow[13] == "12" && setRow[14] == "100")
        #expect(setRow[19] == "12|10|8")

        let emptyRoutine = parse(String(lines[2]))
        #expect(emptyRoutine[2] == "Sketch")
        #expect(emptyRoutine[4] == "ideas only")
        #expect(emptyRoutine.count == RoutineCSVExport.header.count)
    }

    // MARK: - Minimal RFC-4180 reader (test-local; the app importer lives in
    // the app target and package tests must stay self-contained)

    private func parse(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if inQuotes {
                if char == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { current.append("\"") } else if next == "," {
                            fields.append(current); current = ""; inQuotes = false
                        }
                    } else { inQuotes = false }
                } else { current.append(char) }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                fields.append(current); current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }
}
