import SwiftUI

/// Lets a visible tab temporarily yield the shared bottom app chrome while a
/// full-screen interaction needs the canvas. Multiple resident tabs combine
/// with OR semantics so one active request cannot be overwritten by another.
struct BottomChromeHiddenPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func bottomChromeHidden(_ hidden: Bool) -> some View {
        preference(key: BottomChromeHiddenPreferenceKey.self, value: hidden)
    }
}
