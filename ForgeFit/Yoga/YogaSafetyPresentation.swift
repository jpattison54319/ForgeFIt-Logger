import Foundation

/// One presentation value owns both whether the safety sheet is visible and
/// whether it should continue into a class. This prevents a sheet from
/// observing stale state assembled from two independent booleans.
enum YogaSafetyPresentation: String, Identifiable {
    case information
    case startClass

    var id: Self { self }
}
