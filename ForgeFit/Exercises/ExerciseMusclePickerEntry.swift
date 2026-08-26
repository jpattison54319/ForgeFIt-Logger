import Foundation

/// One alphabetized picker row. Some rows are navigation-only groupings, so
/// their label communicates structure without becoming persisted muscle data.
struct ExerciseMusclePickerEntry: Identifiable, Equatable {
    var id: String { group }
    let group: String
    let children: [String]
    let allowsGroupSelection: Bool
}
