import SwiftUI
import UIKit

/// Shared screen chrome: pure-black canvas, a large bold title header with an
/// optional trailing accessory, and a scroll view that keeps its content clear
/// of the floating tab bar.
struct ScreenScaffold<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var subtitle: String? = nil
    var titleFont: Font
    var trailing: Trailing
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        titleFont: Font = .screenTitle,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleFont = titleFont
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(titleFont)
                            .foregroundStyle(theme.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 15))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer()
                    trailing
                }
                .padding(.top, Space.sm)

                content
            }
            .padding(.horizontal, Space.lg)
            .padding(.bottom, Space.tabBarClearance)
            // Root-cause fix for "last row hidden behind the keyboard": see
            // `KeyboardAdaptiveBottomInset` below.
            .keyboardAdaptiveBottomInset()
        }
        .background(theme.background)
        .scrollDismissesKeyboard(.interactively)
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(
        _ title: String,
        subtitle: String? = nil,
        titleFont: Font = .screenTitle,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, subtitle: subtitle, titleFont: titleFont, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Keyboard-aware scroll clearance

/// SwiftUI's automatic keyboard avoidance reliably scrolls a *focused* text
/// field into view, but it does not reliably grow a plain `ScrollView`'s own
/// bottom content inset — especially several layers deep (a `NavigationStack`
/// destination pushed inside `ContentView.appShell`'s tab `ZStack`, which is
/// this app's shape everywhere). The practical symptom: once the focused
/// field scrolls into view, the scroll view's max content offset hasn't
/// actually grown, so rows *below* the focused field that sit behind the
/// keyboard become unreachable — exactly the "can't scroll to the last
/// option while editing" bug. This tracks the live keyboard height from
/// UIKit notifications and adds it as extra bottom padding on the scrollable
/// content, so the true bottom of the content can always be dragged above
/// the keyboard. It composes with the tab bar's `.ignoresSafeArea(.keyboard)`
/// exemption in `ContentView.appShell`: that opt-out only affects the
/// floating tab bar/mini bar layer, so scroll views here still see (and
/// react to) the keyboard height independently, through this modifier.
struct KeyboardAdaptiveBottomInset: ViewModifier {
    @State private var keyboardHeight: CGFloat = 0
    /// Tracks the keyboard's own animation duration from each notification —
    /// a fixed guess drifts from the real slide on some devices and under
    /// accessibility settings, leaving the inset visibly out of step.
    @State private var keyboardAnimation: Animation = .easeOut(duration: 0.25)

    func body(content: Content) -> some View {
        content
            .padding(.bottom, keyboardHeight)
            .animation(keyboardAnimation, value: keyboardHeight)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                syncAnimation(from: note)
                // Height of the keyboard (+ any input accessory, e.g. a
                // `ToolbarItemGroup(placement: .keyboard)` "Done" button)
                // actually overlapping the screen — 0 once it's off-screen,
                // so this never adds slack when the keyboard is hidden.
                let screenHeight = UIScreen.main.bounds.height
                keyboardHeight = max(0, screenHeight - frame.origin.y)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                syncAnimation(from: note)
                keyboardHeight = 0
            }
    }

    private func syncAnimation(from note: Notification) {
        guard let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              duration > 0 else { return }
        keyboardAnimation = .easeOut(duration: duration)
    }
}

extension View {
    /// See `KeyboardAdaptiveBottomInset`.
    func keyboardAdaptiveBottomInset() -> some View {
        modifier(KeyboardAdaptiveBottomInset())
    }
}
