import SwiftUI

enum YogaSafetyAcknowledgement {
    private static let currentVersion = "1"

    static var isAccepted: Bool {
        UserDefaults.standard.string(forKey: YogaGuidanceCatalog.safetyAcknowledgementKey) == currentVersion
    }

    static func accept() {
        UserDefaults.standard.set(currentVersion, forKey: YogaGuidanceCatalog.safetyAcknowledgementKey)
    }
}

enum YogaVoiceGuidancePreference {
    static let key = "yogaVoiceCues"

    static var defaultEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

struct YogaGuidanceSettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage(YogaVoiceGuidancePreference.key) private var voiceCues = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $voiceCues) {
                    SettingsRowLabel(
                        icon: "waveform",
                        iconTint: theme.accent,
                        title: "Voice guidance by default",
                        subtitle: "New yoga blocks start with this choice. Each block can override it."
                    )
                }
                .tint(theme.accent)
                .themedListRow()

                YogaInstructorPicker()
                    .listRowInsets(EdgeInsets())
                    .themedListRow()

                LabeledContent("Talk level", value: "Balanced · adaptive")
                    .font(.body)
                    .foregroundStyle(theme.textPrimary)
                    .themedListRow()
            } header: {
                SettingsSectionHeader(title: "Class audio")
            } footer: {
                Text("ForgeFit prioritizes setup and safe exits, adds more guidance to longer holds, and leaves intentional quiet between cues.")
            }

            Section {
                statusRow

                LabeledContent("Content", value: YogaGuidanceCatalog.contentVersion)
                    .themedListRow()

                LabeledContent("Review", value: YogaGuidanceCatalog.reviewStatus)
                    .themedListRow()
            } header: {
                SettingsSectionHeader(title: "Narration")
            } footer: {
                Text("Gemini is used at build time to narrate fixed, reviewed transcripts. ForgeFit does not send your classes, health data, or voice to a model. Bundled clips play offline.")
            }

            Section {
                yogaSafetyCopy
                    .themedListRow()

                if let url = URL(string: "https://www.nccih.nih.gov/health/yoga-effectiveness-and-safety") {
                    Link(destination: url) {
                        Label("Yoga safety information", systemImage: "safari")
                    }
                    .themedListRow()
                }
            } header: {
                SettingsSectionHeader(title: "Exercise safety")
            } footer: {
                Text("Pose guidance is source-audited general fitness content. It has not yet been independently certified by a yoga teacher and cannot account for your body, health, or surroundings.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .navigationTitle("Yoga guidance")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var statusRow: some View {
        if let manifest = YogaAudioLibrary.manifest, YogaAudioLibrary.isApproved {
            VStack(alignment: .leading, spacing: 4) {
                Label("Bundled Gemini narration", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                Text("Female: \(manifest.voices.female ?? "—") · Male: \(manifest.voices.male ?? "—")")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .themedListRow()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("System-voice fallback", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.warmup)
                Text("Gemini voice auditions have not been approved and bundled in this build yet.")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            .themedListRow()
        }
    }
}

/// First-run gate shown before a guided class. It remains available in
/// Settings after acknowledgement; accepting it does not waive or hide any
/// pose-specific consideration available from an individual pose's details.
struct YogaSafetyView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var startAction: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Image(systemName: "figure.mind.and.body")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(theme.accentForeground)
                        .accessibilityHidden(true)

                    Text("Practice within your range")
                        .font(.title2.bold())
                        .foregroundStyle(theme.textPrimary)

                    yogaSafetyCopy

                    VStack(alignment: .leading, spacing: Space.sm) {
                        safetyPoint(
                            icon: "hand.raised.fill",
                            title: "You are in control",
                            detail: "Pause, modify, use support, or skip any pose. A deeper shape is not a better practice."
                        )
                        safetyPoint(
                            icon: "person.crop.circle.badge.questionmark",
                            title: "General guidance",
                            detail: "This prerecorded class cannot see your alignment or adapt to an injury, pregnancy, health condition, or your surroundings."
                        )
                        safetyPoint(
                            icon: "waveform",
                            title: "Fixed, offline words",
                            detail: "AI narrates source-audited transcripts at build time. No workout or health data is sent to the model during class."
                        )
                    }

                    Text("When unsure, practice with a qualified yoga teacher or ask a healthcare professional who understands your circumstances.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)

                }
                .padding(Space.lg)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if startAction != nil {
                    YogaSafetyActionBar(action: acceptAndStart)
                }
            }
            .background(theme.background)
            .navigationTitle("Yoga safety")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(startAction == nil ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private func acceptAndStart() {
        YogaSafetyAcknowledgement.accept()
        dismiss()
        startAction?()
    }

    private func safetyPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon)
                .foregroundStyle(theme.accentForeground)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}

private var yogaSafetyCopy: some View {
    Text("ForgeFit provides prerecorded general fitness guidance, not individualized instruction or medical advice. Practice only within a comfortable range. Stop if you feel pain, dizziness, numbness, unusual shortness of breath, or feel unwell.")
        .font(.subheadline)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
}
