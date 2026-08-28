import ForgeCore
import SwiftUI

struct SettingsSiriSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @State private var diagnostic: WorkoutIntentDiagnosticSnapshot?

    var body: some View {
        Section {
            SettingsRow(
                icon: "waveform",
                iconTint: theme.accent,
                title: "Control workouts with Siri",
                subtitle: "Start, log sets, control rest, and finish with session exertion."
            ) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.success)
                    .accessibilityLabel("Available")
            }
            .themedListRow()
            .accessibilityIdentifier("settings-app-intent-workouts-available")

            if let diagnostic {
                diagnosticRow(diagnostic)

                Button(role: .destructive) {
                    Task {
                        await WorkoutIntentDiagnosticStore.shared.clear()
                        await refreshDiagnostic()
                    }
                } label: {
                    SettingsRowLabel(
                        icon: "trash",
                        iconTint: theme.danger,
                    title: "Clear last workout start request",
                    subtitle: "Removes this on-device workout-name diagnostic."
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .accessibilityIdentifier("settings-clear-app-intent-diagnostic")
            } else {
                SettingsRowLabel(
                    icon: "text.magnifyingglass",
                    iconTint: theme.textTertiary,
                    title: "No workout start request recorded",
                    subtitle: "Your latest structured workout-name lookup will appear here. Active-workout commands are not logged."
                )
                .themedListRow()
                .accessibilityIdentifier("settings-no-app-intent-diagnostic")
            }
        } header: {
            SettingsSectionHeader(title: "Siri & Shortcuts")
        } footer: {
            Text("Try “Start A X four hundred workout in ForgeFit.” During a workout, ask “What’s next in my ForgeFit workout?”, “Complete my current set in ForgeFit,” “Update my last set in ForgeFit,” “Skip my rest timer in ForgeFit,” or “Finish my workout in ForgeFit.” Siri asks for missing reps, load, RPE or RIR, and final session exertion, then confirms before saving. ForgeFit never receives your Siri audio. Only the latest workout-name lookup—not active-workout commands—is kept in the on-device diagnostic below. When you leave out the app name, Siri decides which workout apps to offer.")
        }
        .task {
            await refreshDiagnostic()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshDiagnostic() }
        }
    }

    private func diagnosticRow(
        _ diagnostic: WorkoutIntentDiagnosticSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text("Last workout request")
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: Space.sm)
                Text(diagnostic.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
            }

            if let queryText = diagnostic.queryText {
                diagnosticLine(label: "Name text", value: queryText)
            } else {
                diagnosticLine(
                    label: "Name text",
                    value: "Resolved directly by the system"
                )
            }

            if let selectedTitle = diagnostic.selectedTitle {
                diagnosticLine(label: "Matched", value: selectedTitle)
            } else if !diagnostic.candidateTitles.isEmpty {
                diagnosticLine(
                    label: "Candidates",
                    value: diagnostic.candidateTitles.joined(separator: ", ")
                )
            }

            diagnosticLine(label: "Result", value: resultText(for: diagnostic.outcome))
        }
        .padding(.vertical, Space.xs)
        .themedListRow()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-app-intent-diagnostic")
    }

    private func diagnosticLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func resultText(
        for outcome: WorkoutIntentDiagnosticSnapshot.Outcome
    ) -> String {
        switch outcome {
        case .queryMatched:
            "Name matched"
        case .queryAmbiguous:
            "More than one workout matched"
        case .queryNoMatch:
            "No workout name matched"
        case .namedWorkout:
            "Opened saved workout"
        case .nextWorkout:
            "Opened next tracked workout"
        case .nextFallback:
            "Used next-workout fallback"
        case .emptyWorkout:
            "Opened empty workout"
        case .unavailable:
            "Workout unavailable"
        }
    }

    private func refreshDiagnostic() async {
        diagnostic = await WorkoutIntentDiagnosticStore.shared.snapshot()
    }
}
