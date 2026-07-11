import Foundation
import SwiftData

extension ModelContext {
    /// Commit a user-initiated edit, reporting failure instead of swallowing
    /// it. On failure the context is rolled back so half-applied in-memory
    /// mutations can't ride along silently with a later unrelated save — the
    /// hazard `try? save()` leaves behind. Returns the error message for an
    /// alert, or `nil` when the save committed.
    ///
    /// Use this for terminal, user-facing writes (Done buttons, finish/delete
    /// flows). Best-effort background fills can keep `try?`.
    @MainActor
    func saveReportingFailure() -> String? {
        do {
            try save()
            return nil
        } catch {
            rollback()
            return error.localizedDescription
        }
    }
}
