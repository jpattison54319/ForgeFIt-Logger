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
            Menu {
                ForEach(ResistanceBandHue.allCases) { hue in
                    Button {
                        preset.hue = hue
                    } label: {
                        Label(hue.title, systemImage: preset.hue == hue ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            } label: {
                ResistanceBandSwatch(hue: preset.hue)
                    .frame(width: 28, height: 28)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Color for \(preset.name)")

            TextField("Band name", text: $preset.name)
                .font(.bodyStrong)
                .foregroundStyle(theme.textPrimary)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("resistance-band-name-\(preset.id.uuidString)")

            TextField("Weight", value: displayWeight, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.bodyStrong)
                .frame(width: 68)
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

    private var displayWeight: Binding<Double> {
        Binding(
            get: { unit.displayValue(fromKilograms: preset.weightKilograms) },
            set: { preset.weightKilograms = unit.kilograms(fromDisplayValue: max(0, $0)) }
        )
    }
}
