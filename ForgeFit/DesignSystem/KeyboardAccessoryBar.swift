import SwiftUI

/// Transparent layout for individually styled Liquid Glass actions immediately
/// above the software keyboard. The safe-area host avoids the iOS 26 keyboard
/// toolbar layout warning without replacing the controls with shared chrome.
struct KeyboardAccessoryBar<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            content
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
    }
}
