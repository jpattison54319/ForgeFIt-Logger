import SwiftUI

/// App-owned keyboard actions that sit immediately above the software
/// keyboard. This avoids the iOS 26 keyboard-toolbar layout warning while
/// preserving a familiar accessory-bar position and 44-point controls.
struct KeyboardAccessoryBar<Content: View>: View {
    @Environment(\.theme) private var theme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            content
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, Space.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: 0.5)
        }
    }
}
