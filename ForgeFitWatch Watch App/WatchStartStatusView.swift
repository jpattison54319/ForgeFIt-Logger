import SwiftUI

struct WatchStartStatusView: View {
    let store: WatchStore

    var body: some View {
        VStack(spacing: 8) {
            if store.isStartingWorkout {
                ProgressView()
                    .accessibilityLabel("Starting workout")
                Text(store.isWaitingForStartSnapshot ? "Syncing workout…" : "Starting on iPhone…")
                    .accessibilityIdentifier("watch-start-status")
            } else if let issue = store.startIssue {
                Text(issue)
                    .accessibilityIdentifier("watch-start-issue")
                Button("Retry Sync", systemImage: "arrow.clockwise") {
                    store.retryWorkoutRecovery()
                }
                .frame(minHeight: 44)
                .buttonStyle(.borderedProminent)
                .tint(WTheme.accent)
                .accessibilityIdentifier("watch-start-retry-sync")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
