import ForgeCore
import SwiftUI

/// Units section: weight unit, cardio distance, effort visibility and scale.
struct SettingsUnitsSection: View {
    @Environment(\.theme) private var theme

    @State private var unit: WeightUnit = Fmt.unit
    @State private var distanceUnit: DistanceUnit = Fmt.distanceUnit
    @AppStorage("weightUnitRaw") private var weightUnitRaw = WeightUnit.lb.rawValue
    @AppStorage("distanceUnitRaw") private var distanceUnitRaw = DistanceUnit.km.rawValue
    @AppStorage("showRPEInLogger") private var showRPEInLogger = false
    @AppStorage("effortScaleRaw") private var effortScaleRaw = "rpe"

    var body: some View {
        Section {
            SettingsRow(title: "Weight unit") {
                Picker("Unit", selection: $unit) {
                    Text("lb").tag(WeightUnit.lb)
                    Text("kg").tag(WeightUnit.kg)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .onChange(of: unit) { _, newValue in
                    Fmt.unit = newValue
                    weightUnitRaw = newValue.rawValue
                }
            }
            .themedListRow()

            SettingsRow(title: "Cardio distance") {
                Picker("Distance", selection: $distanceUnit) {
                    Text("km").tag(DistanceUnit.km)
                    Text("mi").tag(DistanceUnit.mi)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
                .onChange(of: distanceUnit) { _, newValue in
                    Fmt.distanceUnit = newValue
                    distanceUnitRaw = newValue.rawValue
                }
            }
            .themedListRow()

            Toggle(isOn: $showRPEInLogger) {
                SettingsRowLabel(title: "Show effort in logger", subtitle: "Adds an optional effort column for strength sets.")
            }
            .tint(theme.accent)
            .themedListRow()

            if showRPEInLogger {
                SettingsRow(title: "Effort scale", subtitle: effortScaleRaw == "rir" ? "RIR \u{2014} reps in reserve (0 = nothing left)." : "RPE \u{2014} how hard it felt, 6\u{2013}10.") {
                    Picker("Effort scale", selection: $effortScaleRaw) {
                        Text("RPE").tag("rpe")
                        Text("RIR").tag("rir")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                .themedListRow()
            }
        } header: {
            SettingsSectionHeader(title: "Units")
        }
    }
}
