import SwiftUI

struct WatchRecoveryControls: View {
    let store: WatchStore
    @State private var confirmStop = false

    var body: some View {
        if let message = store.recoveryMessage {
            VStack(spacing: 8) {
                Label(message, systemImage: store.isRecordingStopped ? "stop.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message)
                    .accessibilityIdentifier("watch-recovery-status")
                if store.isFinishingWorkout {
                    ProgressView().accessibilityLabel("Saving workout")
                } else {
                    Button(store.isRecordingStopped ? "Resume on Watch" : "Retry Sync") {
                        store.retryWorkoutRecovery()
                    }
                    .frame(minHeight: 44)
                    .buttonStyle(.borderedProminent)
                    .tint(WTheme.accent)
                    .accessibilityIdentifier("watch-retry-sync")
                }
                if store.canStopRecordingOnWatch {
                    Button("Stop on Watch", systemImage: "stop.circle") { confirmStop = true }
                        .frame(minHeight: 44)
                        .buttonStyle(.bordered)
                        .tint(WTheme.danger)
                        .accessibilityIdentifier("watch-stop-recording")
                }
            }
            .frame(maxWidth: .infinity)
            .confirmationDialog("Stop recording on Watch?", isPresented: $confirmStop) {
                Button("Stop Recording", role: .destructive) { store.stopRecordingOnWatch() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops Watch recording without saving it to Health. Your phone workout is kept.")
            }
        }
    }
}
