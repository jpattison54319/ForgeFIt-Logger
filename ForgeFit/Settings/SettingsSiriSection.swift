import ForgeCore
import SwiftUI

struct SettingsSiriSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.theme) private var theme
    @State private var diagnostic: WorkoutIntentDiagnosticSnapshot?
    @State private var showsPhraseIdeas = false

    var body: some View {
        Section {
            SettingsRow(
                icon: "waveform",
                iconTint: theme.accent,
                title: "Workout controls",
                subtitle: "Start, log sets, and finish."
            ) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.success)
                    .accessibilityLabel("Available")
            }
            .themedListRow()
            .accessibilityIdentifier("settings-app-intent-workouts-available")

            Button {
                withAnimation(.snappy) { showsPhraseIdeas.toggle() }
            } label: {
                SettingsRow(icon: "quote.bubble", iconTint: theme.accent, title: "What to say") {
                    Image(systemName: showsPhraseIdeas ? "chevron.down" : "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .themedListRow()
            .accessibilityLabel("What to say")
            .accessibilityValue(showsPhraseIdeas ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("settings-siri-phrase-ideas")

            if showsPhraseIdeas {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("“Start my next workout in ForgeFit”")
                    Text("“What’s next in my ForgeFit workout?”")
                    Text("“Mark my current set complete in ForgeFit”")
                    Text("“Update my last set in ForgeFit”")
                    Text("“Skip my rest timer in ForgeFit”")
                    Text("“Finish my workout in ForgeFit”")
                }
                .font(.subheadline)
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, Space.lg)
                .padding(.vertical, Space.xs)
                .themedListRow()
            }

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
                        title: "Clear last request"
                    )
                }
                .buttonStyle(.plain)
                .themedListRow()
                .accessibilityIdentifier("settings-clear-app-intent-diagnostic")
            } else {
                SettingsRowLabel(
                    icon: "text.magnifyingglass",
                    iconTint: theme.textTertiary,
                    title: "No recent workout request"
                )
                .themedListRow()
                .accessibilityIdentifier("settings-no-app-intent-diagnostic")
            }
        } header: {
            SettingsSectionHeader(title: "Siri & Shortcuts")
        } footer: {
            Text("Only the latest workout-name lookup is saved here.")
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
                    value: "Selected by Siri or Shortcuts"
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
