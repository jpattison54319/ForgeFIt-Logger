import SwiftUI

/// Icon-only increment/decrement tile used by the Myo runner's weight and rep
/// steppers.
///
/// The sizing, background, and content shape all live on the *label* rather
/// than on the `Button`. Modifiers applied to the button itself grow its layout
/// frame but leave both the hit region and the accessibility frame at the
/// glyph's bounds, which is far smaller than the 44×44 minimum — taps that land
/// on the visible tile but outside the icon are dropped.
struct MyoStepperButton: View {
    @Environment(\.theme) private var theme

    /// Visible tile size; also the effective tap target.
    static let size: CGFloat = 56

    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.bold())
                .frame(width: Self.size, height: Self.size)
                .background(theme.surfaceElevated)
                .clipShape(.rect(cornerRadius: Radius.control))
                .contentShape(.rect(cornerRadius: Radius.control))
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
