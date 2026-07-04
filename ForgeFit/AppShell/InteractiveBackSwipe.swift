import SwiftUI
import UIKit

private struct InteractiveBackSwipeEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> EnablerViewController {
        EnablerViewController()
    }

    func updateUIViewController(_ viewController: EnablerViewController, context: Context) {
        viewController.scheduleEnableBackSwipe()
    }

    final class EnablerViewController: UIViewController, UIGestureRecognizerDelegate {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            scheduleEnableBackSwipe()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            scheduleEnableBackSwipe()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            scheduleEnableBackSwipe()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleEnableBackSwipe()
        }

        func scheduleEnableBackSwipe() {
            DispatchQueue.main.async { [weak self] in
                self?.enableBackSwipe()
            }
        }

        private func enableBackSwipe() {
            guard let navigationController = nearestNavigationController() else { return }
            let gesture = navigationController.interactivePopGestureRecognizer
            gesture?.isEnabled = true
            gesture?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            nearestNavigationController()?.viewControllers.count ?? 0 > 1
        }

        private func nearestNavigationController() -> UINavigationController? {
            if let navigationController { return navigationController }

            var parentController = parent
            while let current = parentController {
                if let nav = current as? UINavigationController { return nav }
                if let nav = current.navigationController { return nav }
                parentController = current.parent
            }

            return view.window?.rootViewController?.deepestVisibleNavigationController()
        }
    }
}

private extension UIViewController {
    func deepestVisibleNavigationController() -> UINavigationController? {
        if let nav = self as? UINavigationController { return nav }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.deepestVisibleNavigationController()
        }
        if let split = self as? UISplitViewController {
            return split.viewControllers.last?.deepestVisibleNavigationController()
        }
        if let presentedViewController {
            return presentedViewController.deepestVisibleNavigationController()
        }
        for child in children.reversed() {
            if let nav = child.deepestVisibleNavigationController() { return nav }
        }
        return navigationController
    }
}

extension View {
    /// Restores the native left-edge interactive pop gesture on NavigationStacks
    /// where SwiftUI's navigation bar is hidden in favor of custom headers.
    func interactiveBackSwipeEnabled() -> some View {
        modifier(InteractiveBackSwipeModifier())
    }
}

private struct InteractiveBackSwipeModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var didDismiss = false

    func body(content: Content) -> some View {
        content
            .background(InteractiveBackSwipeEnabler().frame(width: 0, height: 0))
            .simultaneousGesture(edgeSwipeGesture)
    }

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .global)
            .onEnded { value in
                guard !didDismiss,
                      value.startLocation.x <= 24,
                      value.translation.width >= 90,
                      abs(value.translation.height) <= 70,
                      value.predictedEndTranslation.width >= 120 else { return }
                didDismiss = true
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    didDismiss = false
                }
            }
    }
}
