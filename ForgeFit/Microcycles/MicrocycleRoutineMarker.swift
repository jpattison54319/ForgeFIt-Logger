import ForgeCore
import Foundation

enum MicrocycleRoutineMarker {
    static func marker(for index: Int) -> String {
        guard index >= 0 else { return "?" }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var value = index + 1
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(alphabet[value % alphabet.count], at: result.startIndex)
            value /= alphabet.count
        }
        return result
    }

    static func markersByRoutineID(
        in routines: [MicrocycleRoutineSnapshot]
    ) -> [UUID: String] {
        var markers: [UUID: String] = [:]
        for (index, routine) in ordered(routines).enumerated() {
            let marker = marker(for: index)
            for routineID in routine.memberIDs where markers[routineID] == nil {
                markers[routineID] = marker
            }
        }
        return markers
    }

    static func markers(
        for routineIDs: [UUID],
        in routines: [MicrocycleRoutineSnapshot]
    ) -> [String] {
        let completedRoutineIDs = Set(routineIDs)
        return ordered(routines).enumerated().compactMap { index, routine in
            guard !routine.memberIDs.isDisjoint(with: completedRoutineIDs) else {
                return nil
            }
            return marker(for: index)
        }
    }

    private static func ordered(
        _ routines: [MicrocycleRoutineSnapshot]
    ) -> [MicrocycleRoutineSnapshot] {
        routines.sorted {
            if $0.position != $1.position { return $0.position < $1.position }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
