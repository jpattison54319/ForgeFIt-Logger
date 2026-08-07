import SwiftUI

/// Owns the logger chrome's timer observation so timer startup invalidates
/// these small controls instead of the exercise list and its LazyVStack.
struct LoggerRestTimerHost: View {
    @State private var timer = RestTimerController.shared

    var body: some View {
        if timer.isRunning {
            RestTimerBar()
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct LoggerRestTimerControl: View {
    @State private var timer = RestTimerController.shared

    var body: some View {
        if !timer.isRunning {
            RestDurationMenu(
                options: [30, 60, 90, 120, 180, 300],
                allowsOff: false,
                selected: nil,
                onPick: { seconds in
                    if let seconds { timer.start(seconds: seconds, label: "Rest") }
                }
            ) {
                Image(systemName: "timer")
                    .font(.bodyStrong)
                    .frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("Start rest timer")
        }
    }
}
