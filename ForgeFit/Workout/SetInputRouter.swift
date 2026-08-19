import Observation
import SwiftUI

/// Bridges whichever set input currently owns the keyboard to the single
/// keyboard accessory installed at the logger root.
///
/// The logger's inputs live in many sibling views (set rows across cards,
/// mini-set entry pills inside blocks), but the keyboard accessory has to be
/// ONE accessory attached once at the root — per-field UIKit toolbar
/// installation was the source of the "Complete button stops rendering"
/// bug, because a reused UIToolbar attached to a resigned text field comes
/// back blank. Fields register their actions here on focus gain and
/// unregister on focus loss; the root accessory just renders whatever is
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
    /// after every registration, so the root accessory can't get stuck on a
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

    /// Only clears when `token` still owns the accessory — focus moving from
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
    /// UIKit for its keyboard in the same beat this class publishes `active`,
    /// before the newly mounted root has finished subscribing to Observation.
    /// Re-publishing the same value one run-loop tick later guarantees that
    /// second render ourselves, so the actions appear deterministically on
    /// first focus every time.
    private func scheduleAccessoryRefresh(for token: String) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.ownerToken == token, let current = self.active else { return }
            self.active = current
        }
    }
}
