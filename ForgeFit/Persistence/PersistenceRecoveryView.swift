import SwiftUI

/// A last-resort launch surface for a store that cannot open. Loading the
/// normal app against a temporary or empty store would make intact history
/// look deleted and could let the user write into the wrong database, so this
/// screen deliberately blocks access while keeping the original files intact.
struct PersistenceRecoveryView: View {
    let failure: PersistenceLaunchFailure
    let retry: () -> Void

    @State private var isRetrying = false

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("ForgeFit couldn't open your data")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)

                        Text(failure.recoveryMessage)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        Text("Do not delete or reinstall ForgeFit while your history is unavailable.")
                            .font(.body.weight(.semibold))
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        isRetrying = true
                        Task { @MainActor in
                            await Task.yield()
                            retry()
                            isRetrying = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isRetrying {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isRetrying ? "Trying Again…" : "Try Again")
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRetrying)
                    .accessibilityIdentifier("persistence-retry")

                    Text("Support code: \(failure.supportCode)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("persistence-support-code")
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 28)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("persistence-recovery")
    }
}
