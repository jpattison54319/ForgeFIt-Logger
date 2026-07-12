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

    func register(
        token: String,
        onNext: (() -> Void)? = nil,
        completeTitle: String = "Complete",
        onComplete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        ownerToken = token
        active = Actions(onNext: onNext, onComplete: onComplete, completeTitle: completeTitle, onDismiss: onDismiss)
    }

    /// Only clears when `token` still owns the toolbar — focus moving from
    /// field A to field B delivers A's blur and B's focus in no guaranteed
    /// order, and B's registration must survive A's late unregister.
    func unregister(token: String) {
        guard ownerToken == token else { return }
        ownerToken = nil
        active = nil
    }
}
