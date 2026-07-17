import Observation
import SwiftUI

/// Bridges whichever set input currently owns the keyboard to the single
/// keyboard toolbar installed at the logger root.
///
/// The logger's inputs live in many sibling views (set rows across cards,
/// mini-set entry pills inside blocks), but the keyboard accessory has to be
/// ONE toolbar attached once at the root — per-field UIKit toolbar
/// installation was the source of the "Complete button stops rendering"
/// bug, because a reused UIToolbar attached to a resigned text field comes
/// back blank. Fields register their actions here on focus gain and
/// unregister on focus loss; the root toolbar just renders whatever is
/// active.
@MainActor
@Observable
final class SetInputRouter {
    struct Actions {
        var onNext: (() -> Void)?
        var onComplete: () -> Void
        var completeTitle: String
        var onDismiss: () -> Void
    }

    private(set) var active: Actions?
    @ObservationIgnored private var ownerToken: String?
    /// See `scheduleAccessoryRefresh` — a guaranteed second publish shortly
    /// after every registration, so the root toolbar can't get stuck on a
    /// stale/empty accessory view.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    func register(
        token: String,
        onNext: (() -> Void)? = nil,
        completeTitle: String = "Complete",
        onComplete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        ownerToken = token
        active = Actions(onNext: onNext, onComplete: onComplete, completeTitle: completeTitle, onDismiss: onDismiss)
        scheduleAccessoryRefresh(for: token)
    }

    /// Only clears when `token` still owns the toolbar — focus moving from
    /// field A to field B delivers A's blur and B's focus in no guaranteed
    /// order, and B's registration must survive A's late unregister.
    func unregister(token: String) {
        guard ownerToken == token else { return }
        ownerToken = nil
        active = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// On a *freshly presented* logger (right after MiniWorkoutBar collapses
    /// and re-expands it), `ActiveWorkoutLoggerView` and every set row are
    /// brand-new view instances. The very first field to gain focus can ask
    /// UIKit for its keyboard accessory in the same beat this class publishes
    /// `active` — before the root `.toolbar(placement: .keyboard)` has
    /// finished subscribing to this object's Observation and pushed a
    /// `reloadInputViews()` through the SwiftUI/UIKit bridge. When that
    /// happens the keyboard opens with no accessory at all, and the pills
    /// only show up "eventually", once some later, unrelated state change
    /// happens to trigger another toolbar diff. Re-publishing the same
    /// `active` value one run-loop tick later guarantees that second diff
    /// ourselves instead of leaving it to chance, so the pills appear
    /// deterministically on first focus every time.
    private func scheduleAccessoryRefresh(for token: String) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.ownerToken == token, let current = self.active else { return }
            self.active = current
        }
    }
}
