import SwiftUI

/// Standalone body-mass logging sheet (extracted from `MeasuresView` so the
/// quick-action bubble can present it from the app root). Writes straight to
/// Apple Health — bodyweight has no local model.
struct LogWeightSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var health = HealthMetricsStore.shared
    @State private var draft: String
    @State private var saving = false
    /// Health write failed (usually write access off) — shown inline so the
    /// save isn't a silent no-op; the draft is kept so nothing is retyped.
    @State private var saveError: String?

    init() {
        // Prefill with the latest weigh-in, mirroring Measures' Log Weight
        // button. The draft stays a plain string parsed only at save time —
        // per-keystroke numeric round-tripping eats a trailing "62.".
        _draft = State(initialValue:
            HealthMetricsStore.shared.bodyweightSeries.last.map { Fmt.load($0.value) } ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.lg) {
                FieldLabel("Weight")
                HStack(spacing: Space.sm) {
                    DarkTextField(text: $draft, placeholder: "180")
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("log-weight-field")
                    Text(Fmt.unit.suffix)
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textSecondary)
                }
                Text("ForgeFit writes this weigh-in to Apple Health so your other health apps can use the same source of truth.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                if let saveError {
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.danger)
                        Text(saveError)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            .padding(Space.lg)
            .background(theme.background)
            .onChange(of: draft) { saveError = nil }
            .navigationTitle("Log Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("log-weight-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving..." : "Save") { save() }
                        .font(.bodyStrong)
                        .disabled(saving || Fmt.loadKilograms(from: draft) == nil)
                        .accessibilityIdentifier("log-weight-save")
                }
            }
        }
    }

    private func save() {
        guard let kilograms = Fmt.loadKilograms(from: draft) else { return }
        saving = true
        saveError = nil
        Task {
            let saved = await HealthService.shared.logBodyMass(kilograms: kilograms)
            await MainActor.run {
                saving = false
                if saved {
                    dismiss()
                    health.refresh(force: true)
                } else {
                    // Say why nothing happened instead of silently flipping
                    // the button back — write access is the usual culprit.
                    saveError = "Couldn't save to Apple Health. Allow write access in Health → Sharing → Apps → ForgeFit, then try again."
                }
            }
        }
    }
}
