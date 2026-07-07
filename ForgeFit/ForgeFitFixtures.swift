import ForgeCore
import ForgeData
import Foundation

nonisolated enum ForgeFitDemo {
    static let userID = UUID(uuidString: "00000000-0000-7000-8000-000000000901")!
    static let machinePressNoteID = UUID(uuidString: "00000000-0000-7000-8000-000000000902")!

    static let starterRoutineID = UUID(uuidString: "00000000-0000-7000-8000-000000000910")!
    static let starterRoutineExerciseID = UUID(uuidString: "00000000-0000-7000-8000-000000000911")!
    static let starterRoutineSetID = UUID(uuidString: "00000000-0000-7000-8000-000000000912")!
}

enum DisplayFormatters {
    static func kilograms(_ value: Double?) -> String {
        guard let value else { return "-" }
        return value.formatted(.number.precision(.fractionLength(0...1))) + " kg"
    }

    static func number(_ value: Double?) -> String {
        guard let value else { return "-" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    static func kilometers(_ meters: Double?) -> String {
        guard let meters else { return "-" }
        let kilometers = meters / 1_000
        return kilometers.formatted(.number.precision(.fractionLength(0...2))) + " km"
    }

    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "-" }
        let minutes = seconds / 60
        return "\(minutes) min"
    }

    static func exerciseName(for id: UUID, in exercises: [ExerciseLibraryModel]) -> String {
        exercises.first { $0.id == id }?.name ?? "Unknown exercise"
    }
}
