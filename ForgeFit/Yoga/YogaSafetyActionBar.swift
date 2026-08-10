import SwiftUI

/// A persistent action for the first-run safety gate. Keeping it outside the
/// scroll content makes the next step visible at every Dynamic Type size.
struct YogaSafetyActionBar: View {
    @Environment(\.theme) private var theme

    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            Button(action: action) {
                Label("I Understand · Start Class", systemImage: "play.fill")
                    .font(.bodyStrong)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.accent)
                    .clipShape(.rect(cornerRadius: Radius.control))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityIdentifier("accept-yoga-safety")
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
        }
        .background(theme.background)
    }
}
