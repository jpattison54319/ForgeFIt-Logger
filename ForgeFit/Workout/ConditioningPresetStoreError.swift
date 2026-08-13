import Foundation

enum ConditioningPresetStoreError: LocalizedError {
    case emptyName
    case emptySection
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a name for this preset."
        case .emptySection: "Add at least one movement before saving this preset."
        case .encodingFailed: "The conditioning block couldn't be saved as a preset."
        }
    }
}
