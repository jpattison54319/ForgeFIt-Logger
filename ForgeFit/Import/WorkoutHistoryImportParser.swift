import CryptoKit
import Foundation
import ForgeCore

enum WorkoutImportSource: String, Codable, Sendable {
    case hevy
    case strong
    case fitbod
    case heavySet
    case forgeFitJSON
    case genericCSV

    var displayName: String {
        switch self {
        case .hevy: "Hevy"
        case .strong: "Strong"
        case .fitbod: "Fitbod"
        case .heavySet: "HeavySet"
        case .forgeFitJSON: "ForgeFit JSON"
        case .genericCSV: "CSV"
        }
    }
}

struct WorkoutImportWarning: Identifiable, Hashable, Sendable {
    let id = UUID()
    var message: String
}

struct ImportedWorkoutDraft: Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var startedAt: Date
    var endedAt: Date
    var notes: String?
    var exercises: [ImportedExerciseDraft]
    var externalID: String?
    var fingerprint: String

    var setCount: Int { exercises.reduce(0) { $0 + $1.sets.count } }
}

struct ImportedExerciseDraft: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var notes: String?
    var supersetID: Int?
    var sets: [ImportedSetDraft]
}

struct ImportedSetDraft: Identifiable, Hashable, Sendable {
    let id: String
    var index: Int
    var setType: SetType
    var weightKg: Double?
    var reps: Int?
    var distanceMeters: Double?
    var durationSeconds: Int?
    var rpe: Double?
    var notes: String?
}

struct WorkoutHistoryImportParseResult: Sendable {
    var source: WorkoutImportSource
    var fileName: String
    var workouts: [ImportedWorkoutDraft]
    var warnings: [WorkoutImportWarning]
}

enum WorkoutHistoryImportParser {
    static func parse(data: Data, fileName: String) throws -> WorkoutHistoryImportParseResult {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if fileName.lowercased().hasSuffix(".json") || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return try parseForgeFitJSON(data: data, fileName: fileName)
        }
        return try parseCSV(data: data, fileName: fileName)
    }
}

private extension WorkoutHistoryImportParser {
    static func parseCSV(data: Data, fileName: String) throws -> WorkoutHistoryImportParseResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw WorkoutImportError.unreadableFile
        }
        let rows = CSVTable.parse(text)
        guard let header = rows.first, !header.isEmpty else { throw WorkoutImportError.emptyFile }
        let records = rows.dropFirst().map { CSVRecord(header: header, values: $0) }
            .filter { !$0.isBlank }
        guard !records.isEmpty else { throw WorkoutImportError.emptyFile }

        let normalizedHeaders = Set(header.map(CSVRecord.normalize(_:)))
        let source = detectSource(headers: normalizedHeaders)
        let mapper = CSVImportMapper(source: source, headers: normalizedHeaders)
        var warnings: [WorkoutImportWarning] = []
        var grouped: [String: WorkoutBuilder] = [:]
        var order: [String] = []

        for (rowIndex, record) in records.enumerated() {
            guard let exerciseName = mapper.exerciseName(record), !exerciseName.isEmpty else {
                warnings.append(.init(message: "Skipped row \(rowIndex + 2): missing exercise name."))
                continue
            }
            guard let start = mapper.startDate(record) else {
                warnings.append(.init(message: "Skipped row \(rowIndex + 2): missing or unreadable workout date."))
                continue
            }
            let title = mapper.workoutTitle(record) ?? "Imported Workout"
            let end = mapper.endDate(record) ?? mapper.endFromDuration(record, start: start) ?? start
            let workoutKey = "\(title)|\(Int(start.timeIntervalSince1970))|\(Int(end.timeIntervalSince1970))"
            if grouped[workoutKey] == nil {
                grouped[workoutKey] = WorkoutBuilder(
                    title: title,
                    startedAt: start,
                    endedAt: end,
                    notes: mapper.workoutNotes(record)
                )
                order.append(workoutKey)
            }

            let set = ImportedSetDraft(
                id: "\(rowIndex)-set",
                index: mapper.setIndex(record) ?? grouped[workoutKey]?.nextSetIndex(for: exerciseName) ?? 0,
                setType: mapper.setType(record),
                weightKg: mapper.weightKg(record),
                reps: mapper.int(record, keys: CSVImportMapper.repsKeys),
                distanceMeters: mapper.distanceMeters(record),
                durationSeconds: mapper.durationSeconds(record),
                rpe: mapper.double(record, keys: CSVImportMapper.rpeKeys),
                notes: mapper.setNotes(record)
            )
            grouped[workoutKey]?.append(
                set: set,
                exerciseName: exerciseName,
                exerciseNotes: mapper.exerciseNotes(record),
                supersetID: mapper.supersetID(record)
            )
        }

        let workouts = order.compactMap { key -> ImportedWorkoutDraft? in
            guard let builder = grouped[key] else { return nil }
            return builder.draft(source: source)
        }
        guard !workouts.isEmpty else { throw WorkoutImportError.noImportableWorkouts }

        return WorkoutHistoryImportParseResult(
            source: source,
            fileName: fileName,
            workouts: workouts,
            warnings: warnings
        )
    }

    static func parseForgeFitJSON(data: Data, fileName: String) throws -> WorkoutHistoryImportParseResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file: ForgeFitImportFile
        if let object = try? decoder.decode(ForgeFitImportFile.self, from: data) {
            file = object
        } else {
            let workouts = try decoder.decode([ForgeFitImportWorkout].self, from: data)
            file = ForgeFitImportFile(workouts: workouts)
        }

        let drafts = file.workouts.enumerated().compactMap { index, workout -> ImportedWorkoutDraft? in
            guard let start = workout.startedAt else { return nil }
            let end = workout.endedAt ?? start
            let exercises = workout.exercises.enumerated().map { exerciseIndex, exercise in
                ImportedExerciseDraft(
                    id: "\(index)-\(exerciseIndex)-\(exercise.name)",
                    name: exercise.name,
                    notes: exercise.notes,
                    supersetID: exercise.supersetID,
                    sets: exercise.sets.enumerated().map { setIndex, set in
                        ImportedSetDraft(
                            id: "\(index)-\(exerciseIndex)-\(setIndex)",
                            index: set.index ?? setIndex,
                            setType: SetType(rawValue: set.setType ?? "") ?? .working,
                            weightKg: set.weightKg,
                            reps: set.reps,
                            distanceMeters: set.distanceMeters,
                            durationSeconds: set.durationSeconds,
                            rpe: set.rpe,
                            notes: set.notes
                        )
                    }
                )
            }
            let draft = ImportedWorkoutDraft(
                id: workout.externalID ?? "\(index)-\(workout.title ?? "Workout")-\(start.timeIntervalSince1970)",
                title: workout.title ?? "Imported Workout",
                startedAt: start,
                endedAt: end,
                notes: workout.notes,
                exercises: exercises,
                externalID: workout.externalID,
                fingerprint: ""
            )
            return draft.withFingerprint(source: .forgeFitJSON)
        }

        guard !drafts.isEmpty else { throw WorkoutImportError.noImportableWorkouts }
        return WorkoutHistoryImportParseResult(
            source: .forgeFitJSON,
            fileName: fileName,
            workouts: drafts,
            warnings: []
        )
    }

    static func detectSource(headers: Set<String>) -> WorkoutImportSource {
        if headers.contains("starttime"), headers.contains("exercisetitle"), headers.contains("setindex") {
            return .hevy
        }
        if headers.contains("workoutname"), headers.contains("exercisename"), headers.contains("weightunit") {
            return .strong
        }
        if headers.contains("exercise"), headers.contains("durations"), headers.contains(where: { $0.hasPrefix("weight") }) {
            return .fitbod
        }
        if headers.contains("weightkg"), headers.contains("weightlbs"), headers.contains("kind") {
            return .heavySet
        }
        return .genericCSV
    }
}

enum WorkoutImportError: LocalizedError {
    case unreadableFile
    case emptyFile
    case noImportableWorkouts

    var errorDescription: String? {
        switch self {
        case .unreadableFile: "ForgeFit could not read this file."
        case .emptyFile: "This file does not contain workout rows."
        case .noImportableWorkouts: "ForgeFit could not find importable workouts in this file."
        }
    }
}

private struct CSVImportMapper {
    let source: WorkoutImportSource
    let headers: Set<String>

    static let titleKeys = ["title", "workoutname", "workout", "workouttitle", "name"]
    static let exerciseKeys = ["exercisetitle", "exercisename", "exercise", "ename"]
    static let startKeys = ["starttime", "date", "sessiondate", "mydate", "startedat"]
    static let endKeys = ["endtime", "endedat"]
    static let setIndexKeys = ["setindex", "setorder", "set", "setnumber", "order"]
    static let setTypeKeys = ["settype", "type", "kind"]
    static let repsKeys = ["reps", "repcount", "repetitions"]
    static let rpeKeys = ["rpe", "effortrating"]
    static let notesKeys = ["notes", "note", "setnotes"]
    static let exerciseNotesKeys = ["exercisenotes"]
    static let workoutNotesKeys = ["description", "workoutnotes", "workoutnote"]
    static let durationKeys = ["durationseconds", "seconds", "durations", "duration", "time"]
    static let workoutDurationKeys = ["workoutduration"]
    static let supersetKeys = ["supersetid", "superset"]

    func workoutTitle(_ record: CSVRecord) -> String? {
        string(record, keys: Self.titleKeys)
    }

    func exerciseName(_ record: CSVRecord) -> String? {
        string(record, keys: Self.exerciseKeys)
    }

    func workoutNotes(_ record: CSVRecord) -> String? {
        string(record, keys: Self.workoutNotesKeys)
    }

    func exerciseNotes(_ record: CSVRecord) -> String? {
        string(record, keys: Self.exerciseNotesKeys)
    }

    func setNotes(_ record: CSVRecord) -> String? {
        string(record, keys: Self.notesKeys) ?? exerciseNotes(record)
    }

    func startDate(_ record: CSVRecord) -> Date? {
        date(record, keys: Self.startKeys)
    }

    func endDate(_ record: CSVRecord) -> Date? {
        date(record, keys: Self.endKeys)
    }

    func endFromDuration(_ record: CSVRecord, start: Date) -> Date? {
        if let seconds = durationText(record, keys: Self.workoutDurationKeys) {
            return start.addingTimeInterval(TimeInterval(seconds))
        }
        return nil
    }

    func setIndex(_ record: CSVRecord) -> Int? {
        int(record, keys: Self.setIndexKeys)
    }

    func supersetID(_ record: CSVRecord) -> Int? {
        int(record, keys: Self.supersetKeys)
    }

    func setType(_ record: CSVRecord) -> SetType {
        if let warmup = string(record, keys: ["iswarmup"])?.lowercased(), ["1", "true", "yes"].contains(warmup) {
            return .warmup
        }
        let raw = string(record, keys: Self.setTypeKeys)?.lowercased() ?? "normal"
        if raw.contains("warm") || raw == "w" { return .warmup }
        if raw.contains("drop") || raw == "d" { return .drop }
        if raw.contains("fail") || raw.contains("amrap") { return .amrap }
        if raw.contains("back") { return .backoff }
        return .working
    }

    func weightKg(_ record: CSVRecord) -> Double? {
        if let kg = double(record, keys: ["weightkg", "weightkg"]) { return kg }
        if let lbs = double(record, keys: ["weightlbs", "weightlb"]) { return lbs / 2.2046226218 }
        guard let weight = double(record, keys: ["weight", "load", "mass"]) else { return nil }
        let unit = string(record, keys: ["weightunit", "unit", "weightunits"])?.lowercased() ?? inferredWeightUnit
        if unit.contains("lb") { return weight / 2.2046226218 }
        return weight
    }

    func distanceMeters(_ record: CSVRecord) -> Double? {
        if let meters = double(record, keys: ["distancem", "distanceinmeters"]) { return meters }
        if let km = double(record, keys: ["distancekm"]) { return km * 1000 }
        if let miles = double(record, keys: ["distancemiles", "distancemi"]) { return miles * 1609.344 }
        guard let distance = double(record, keys: ["distance"]) else { return nil }
        let unit = string(record, keys: ["distanceunit", "distanceunits"])?.lowercased() ?? inferredDistanceUnit
        if unit.contains("mi") { return distance * 1609.344 }
        if unit == "m" || unit.contains("meter") { return distance }
        if unit.contains("yd") { return distance * 0.9144 }
        if unit.contains("ft") { return distance * 0.3048 }
        return distance * 1000
    }

    func durationSeconds(_ record: CSVRecord) -> Int? {
        durationText(record, keys: Self.durationKeys)
    }

    func string(_ record: CSVRecord, keys: [String]) -> String? {
        for key in keys {
            if let value = record[key], !value.isEmpty { return value }
        }
        return nil
    }

    func int(_ record: CSVRecord, keys: [String]) -> Int? {
        guard let value = string(record, keys: keys) else { return nil }
        guard let number = Double(value.replacingOccurrences(of: ",", with: "")) else { return nil }
        return Int(number)
    }

    func double(_ record: CSVRecord, keys: [String]) -> Double? {
        guard let value = string(record, keys: keys) else { return nil }
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }

    private func date(_ record: CSVRecord, keys: [String]) -> Date? {
        guard let value = string(record, keys: keys) else { return nil }
        return DateImportParser.parse(value)
    }

    private func durationText(_ record: CSVRecord, keys: [String]) -> Int? {
        guard let raw = string(record, keys: keys) else { return nil }
        if let numeric = Double(raw) { return Int(numeric.rounded()) }
        return DurationImportParser.parse(raw)
    }

    private var inferredWeightUnit: String {
        if headers.contains("weightlbs") { return "lb" }
        return "kg"
    }

    private var inferredDistanceUnit: String {
        if headers.contains("distancemiles") { return "mi" }
        if headers.contains("distancem") { return "m" }
        return "km"
    }
}

private struct WorkoutBuilder {
    var title: String
    var startedAt: Date
    var endedAt: Date
    var notes: String?
    private var exercises: [String: ExerciseBuilder] = [:]
    private var exerciseOrder: [String] = []

    init(title: String, startedAt: Date, endedAt: Date, notes: String?) {
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
    }

    mutating func append(set: ImportedSetDraft, exerciseName: String, exerciseNotes: String?, supersetID: Int?) {
        let key = "\(exerciseName)|\(supersetID.map(String.init) ?? "-")"
        if exercises[key] == nil {
            exercises[key] = ExerciseBuilder(name: exerciseName, notes: exerciseNotes, supersetID: supersetID)
            exerciseOrder.append(key)
        }
        exercises[key]?.sets.append(set)
    }

    func nextSetIndex(for exerciseName: String) -> Int {
        exercises
            .filter { $0.value.name == exerciseName }
            .flatMap(\.value.sets)
            .count
    }

    func draft(source: WorkoutImportSource) -> ImportedWorkoutDraft {
        let exerciseDrafts = exerciseOrder.compactMap { key -> ImportedExerciseDraft? in
            guard let exercise = exercises[key] else { return nil }
            return ImportedExerciseDraft(
                id: "\(key)-\(exerciseOrder.firstIndex(of: key) ?? 0)",
                name: exercise.name,
                notes: exercise.notes,
                supersetID: exercise.supersetID,
                sets: exercise.sets.sorted { $0.index < $1.index }
            )
        }
        let base = ImportedWorkoutDraft(
            id: "\(title)-\(startedAt.timeIntervalSince1970)",
            title: title,
            startedAt: startedAt,
            endedAt: endedAt,
            notes: notes,
            exercises: exerciseDrafts,
            externalID: nil,
            fingerprint: ""
        )
        return base.withFingerprint(source: source)
    }
}

private struct ExerciseBuilder {
    var name: String
    var notes: String?
    var supersetID: Int?
    var sets: [ImportedSetDraft] = []
}

private extension ImportedWorkoutDraft {
    func withFingerprint(source: WorkoutImportSource) -> ImportedWorkoutDraft {
        var copy = self
        let rows = exercises.map { exercise in
            let setRows = exercise.sets.map {
                "\($0.index):\($0.setType.rawValue):\($0.weightKg ?? -1):\($0.reps ?? -1):\($0.distanceMeters ?? -1):\($0.durationSeconds ?? -1):\($0.rpe ?? -1)"
            }.joined(separator: "|")
            return "\(exercise.name):\(exercise.supersetID ?? -1):\(setRows)"
        }.joined(separator: "||")
        let raw = "\(source.rawValue)|\(title)|\(Int(startedAt.timeIntervalSince1970))|\(Int(endedAt.timeIntervalSince1970))|\(rows)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        copy.fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        return copy
    }
}

private struct CSVTable {
    static func parse(_ text: String) -> [[String]] {
        let delimiter = detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()

        while let scalar = iterator.next() {
            if scalar == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == delimiter {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if scalar == delimiter, !inQuotes {
                row.append(field)
                field = ""
            } else if scalar == "\n", !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if scalar != "\r" {
                field.append(scalar)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let candidates: [Character] = [",", ";", "\t"]
        return candidates.max {
            quoteAwareCount(firstLine, delimiter: $0) < quoteAwareCount(firstLine, delimiter: $1)
        } ?? ","
    }

    private static func quoteAwareCount(_ line: String, delimiter: Character) -> Int {
        var count = 0
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle() }
            if character == delimiter, !inQuotes { count += 1 }
        }
        return count
    }
}

private struct CSVRecord {
    private var values: [String: String]

    init(header: [String], values row: [String]) {
        var result: [String: String] = [:]
        for (index, key) in header.enumerated() {
            let value = index < row.count ? row[index] : ""
            result[Self.normalize(key)] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.values = result
    }

    subscript(key: String) -> String? {
        values[Self.normalize(key)]
    }

    var isBlank: Bool {
        values.values.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    nonisolated static func normalize(_ header: String) -> String {
        header
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .filter { $0.isLetter || $0.isNumber }
    }
}

private enum DateImportParser {
    static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let iso = ISO8601DateFormatter().date(from: text) { return iso }

        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let formatters: [DateFormatter] = {
        let formats = [
            "MMM d, yyyy, h:mm a",
            "MMM d, yyyy h:mm a",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm:ss",
            "MM/dd/yyyy h:mm a",
            "M/d/yyyy h:mm a",
            "dd/MM/yyyy HH:mm:ss",
            "dd/MM/yyyy HH:mm"
        ]
        return formats.map {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = $0
            return formatter
        }
    }()
}

private enum DurationImportParser {
    static func parse(_ raw: String) -> Int? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
        }

        var seconds = 0
        let pattern = #"(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours|m|min|mins|minute|minutes|s|sec|secs|second|seconds)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]) else { continue }
            let unit = String(text[unitRange])
            if unit.hasPrefix("h") { seconds += Int(value * 3600) }
            else if unit.hasPrefix("m") { seconds += Int(value * 60) }
            else { seconds += Int(value) }
        }
        return seconds > 0 ? seconds : nil
    }
}

private struct ForgeFitImportFile: Decodable {
    var workouts: [ForgeFitImportWorkout]
}

private struct ForgeFitImportWorkout: Decodable {
    var title: String?
    var startedAt: Date?
    var endedAt: Date?
    var notes: String?
    var externalID: String?
    var exercises: [ForgeFitImportExercise]
}

private struct ForgeFitImportExercise: Decodable {
    var name: String
    var notes: String?
    var supersetID: Int?
    var sets: [ForgeFitImportSet]
}

private struct ForgeFitImportSet: Decodable {
    var index: Int?
    var setType: String?
    var weightKg: Double?
    var reps: Int?
    var distanceMeters: Double?
    var durationSeconds: Int?
    var rpe: Double?
    var notes: String?
}
