import SwiftUI

struct ResistanceBandSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var profile = ResistanceBandProfileStore.load()
    @State private var unit = Fmt.unit

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Card {
                    VStack(alignment: .leading, spacing: Space.md) {
                        Text("Band Colors")
                            .font(.cardTitle)
                            .foregroundStyle(theme.textPrimary)
                        Text("Each color resolves to the equivalent load used in workout volume and analytics. Band tension varies with stretch, so set the values for your own bands.")
                            .font(.body)
                            .foregroundStyle(theme.textSecondary)

                        ForEach($profile.presets) { $preset in
                            ResistanceBandPresetRow(
                                preset: $preset,
                                unit: unit,
                                canDelete: profile.presets.count > 1,
                                onDelete: { delete(preset.id) }
                            )
                            if preset.id != profile.presets.last?.id {
                                Divider().overlay(theme.separator)
                            }
                        }

                        Button("Add Band", systemImage: "plus", action: addBand)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.accentForeground)
                            .minimumTouchTarget()
                            .accessibilityIdentifier("add-resistance-band")
                    }
                }

                Button("Reset to defaults", action: reset)
                    .font(.bodyStrong)
                    .foregroundStyle(theme.textSecondary)
                    .minimumTouchTarget()
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
        .background(theme.background)
        .navigationTitle("Resistance Bands")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: profile) { _, updated in
            ResistanceBandProfileStore.save(updated)
        }
    }

    private func addBand() {
        profile.addPreset()
    }

    private func delete(_ id: UUID) {
        guard profile.presets.count > 1 else { return }
        profile.presets.removeAll { $0.id == id }
    }

    private func reset() {
        profile = .standard
    }
}

private struct ResistanceBandPresetRow: View {
    @Environment(\.theme) private var theme
    @Binding var preset: ResistanceBandPreset
    let unit: WeightUnit
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            // ScrollSafeMenu, not SwiftUI's `Menu`: a `Menu` renders every
            // `systemImage` in the accent tint, so all ten swatches came out
            // the same yellow. `iconColor` survives into UIMenu as an
            // always-original template, the way superset dots keep theirs —
            // and the label stops claiming this ScrollView's scroll gesture.
            ScrollSafeMenu(sections: [hueItems]) {
                ResistanceBandSwatch(hue: preset.hue)
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Color for \(preset.name)")

            DarkTextField(
                text: $preset.name,
                placeholder: "Band name",
                accessibilityIdentifier: "resistance-band-name-\(preset.id.uuidString)"
            )

            // The filled field container is the affordance that says
            // "editable" — a bare value read as static label text.
            OptionalLoadField(
                placeholder: "0",
                value: weightKilograms,
                unit: unit,
                width: 84
            )
            .accessibilityIdentifier("resistance-band-weight-\(preset.id.uuidString)")

            Text(unit.suffix)
                .font(.label)
                .foregroundStyle(theme.textSecondary)

            Button("Delete band", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .minimumTouchTarget()
                .disabled(!canDelete)
        }
    }

    private var hueItems: [ScrollSafeMenuItem] {
        ResistanceBandHue.allCases.map { hue in
            ScrollSafeMenuItem(
                title: hue.title,
                systemImage: "circle.fill",
                iconColor: hue.color,
                isChecked: preset.hue == hue,
                action: { preset.hue = hue }
            )
        }
    }

    /// `OptionalLoadField` owns the kg↔display conversion through `Fmt` and
    /// the focus-aware draft, so a fractional band load can be typed without
    /// the trailing "." being eaten mid-keystroke.
    private var weightKilograms: Binding<Double?> {
        Binding(
            get: { preset.weightKilograms },
            set: { preset.weightKilograms = max(0, $0 ?? 0) }
        )
    }
}
