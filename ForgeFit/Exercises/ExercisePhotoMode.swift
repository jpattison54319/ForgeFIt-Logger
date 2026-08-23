import Foundation

/// How the athlete wants their exercise photo presented in the editor.
///
/// The mode is deliberately editor-only. The stored photos remain the source
/// of truth, so existing exercises need no migration and cannot drift out of
/// sync with a separate presentation flag.
enum ExercisePhotoMode: String, CaseIterable, Identifiable {
    case single
    case startAndEnd

    var id: Self { self }

    var title: String {
        switch self {
        case .single: "Single photo"
        case .startAndEnd: "Start + end"
        }
    }

    static func inferred(from photos: ExercisePhotoSet) -> Self {
        photos.animates ? .startAndEnd : .single
    }
}

extension ExercisePhotoSet {
    /// A single photo has no positional meaning. Store it in the canonical
    /// start slot so reopening the editor and later adding an end position are
    /// predictable, including for legacy end-only exercises.
    var normalizedSinglePhoto: Self {
        ExercisePhotoSet(start: start ?? end)
    }

    func singlePhoto(keeping slot: ExercisePhotoSlot) -> Self {
        ExercisePhotoSet(start: self[slot] ?? start ?? end)
    }
}
