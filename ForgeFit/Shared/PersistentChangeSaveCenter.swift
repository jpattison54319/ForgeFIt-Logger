import Observation
import SwiftUI

/// Presents store-write failures above whichever editing surface initiated
/// them. The retry closure keeps a failed user edit actionable even when its
/// sheet or navigation destination has already started dismissing.
@MainActor
@Observable
final class PersistentChangeSaveCenter {
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        let message: String
    }

    static let shared = PersistentChangeSaveCenter()

    private(set) var failure: Failure?
    @ObservationIgnored private var retryAction: (@MainActor () -> String?)?

    /// Run a user-requested persistent operation, retaining an exact retry of
    /// the same operation when it throws. Callers use `onSuccess` for state
    /// transitions that must not happen before the write commits.
    @discardableResult
    func perform(
        _ operation: @escaping @MainActor () throws -> Void,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        do {
            try operation()
            // A later save of the shared main context also commits any edit
            // retained after an earlier failure, so a successful write
            // resolves the currently presented persistence warning.
            dismiss()
            onSuccess()
            return true
        } catch {
            report(error.localizedDescription) {
                do {
                    try operation()
                    onSuccess()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            return false
        }
    }

    /// Bridges terminal operations that already return their user-facing
    /// persistence failure (for example workout finish/discard). Completion
    /// still waits for a successful first attempt or exact Retry.
    @discardableResult
    func performReportingFailure(
        _ operation: @escaping @MainActor () -> String?,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) -> Bool {
        guard let message = operation() else {
            dismiss()
            onSuccess()
            return true
        }
        report(message) {
            guard let retryMessage = operation() else {
                onSuccess()
                return nil
            }
            return retryMessage
        }
        return false
    }

    func report(_ message: String, retry: @escaping @MainActor () -> String?) {
        failure = Failure(message: message)
        retryAction = retry
    }

    func retry() {
        guard let retryAction else {
            dismiss()
            return
        }
        failure = nil
        self.retryAction = nil

        // Let SwiftUI finish dismissing the current alert before presenting a
        // second failure. Otherwise an immediate retry error can be dropped by
        // the alert's own dismissal transaction.
        Task { @MainActor in
            await Task.yield()
            if let message = retryAction() {
                report(message, retry: retryAction)
            }
        }
    }

    func dismiss() {
        failure = nil
        retryAction = nil
    }

    /// SwiftUI writes `false` to an alert binding as part of its dismissal
    /// transaction. Keep the retry closure alive until the selected button's
    /// action has run; otherwise action/binding ordering could eat a retry.
    func endAlertPresentation() {
        failure = nil
    }
}

private struct PersistentChangeSaveAlertModifier: ViewModifier {
    @State private var center = PersistentChangeSaveCenter.shared

    func body(content: Content) -> some View {
        let failureMessage = center.failure?.message ?? ""
        content.alert(
            "Changes Weren't Saved",
            isPresented: Binding(
                get: { center.failure != nil },
                set: { if !$0 { center.endAlertPresentation() } }
            )
        ) {
            Button("Retry", action: center.retry)
            Button("Keep Editing", role: .cancel, action: center.dismiss)
        } message: {
            Text("ForgeFit couldn't write this change to its database. The change remains pending while the app stays open.\n\n\(failureMessage)")
        }
    }
}

extension View {
    /// Makes persistence failures visible without forcing every deeply nested
    /// editor to own a duplicate alert implementation.
    func persistentChangeSaveAlert() -> some View {
        modifier(PersistentChangeSaveAlertModifier())
    }
}
