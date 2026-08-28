import Foundation

/// Shared lost-update contract for editor-local text. Remote/model changes may
/// refresh an untouched draft, while actual local typing remains authoritative
/// until its explicit commit boundary.
nonisolated enum LocalTextDraftPolicy {
    static func synchronizedDraft(
        currentDraft: String,
        modelText: String?,
        isDirty: Bool
    ) -> String {
        isDirty ? currentDraft : (modelText ?? "")
    }

    static func shouldCommit(
        draft: String,
        modelText: String?,
        isDirty: Bool
    ) -> Bool {
        isDirty && modelText != draft
    }
}
