import ForgeCore
import SwiftUI

/// Barbell plate calculator: shows the per-side loadout for a target weight
/// using the user's bar + plate inventory, with a closest-loadable fallback
/// and one-tap apply back to the set.
struct PlateCalculatorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let displayUnit: WeightUnit
    /// Target in kilograms (data-layer unit); nil = start from the bar.
    let initialTargetKg: Double?
    let onApply: (Double) -> Void

    @State private var inventory: PlateInventory
    @State private var targetText: String

    init(displayUnit: WeightUnit, initialTargetKg: Double?, onApply: @escaping (Double) -> Void) {
        self.displayUnit = displayUnit
        self.initialTargetKg = initialTargetKg
        self.onApply = onApply
        let inventory = PlateInventoryStore.load(unit: displayUnit)
        _inventory = State(initialValue: inventory)
        let initial = initialTargetKg.map { Fmt.load($0, unit: displayUnit) } ?? ""
        _targetText = State(initialValue: initial)
    }

    private var targetKg: Double? {
        Fmt.loadKilograms(from: targetText, unit: displayUnit)
    }

    private var solution: PlateSolution? {
        guard let targetKg, targetKg > 0 else { return nil }
        return PlateSolution.solve(targetKg: targetKg, inventory: inventory)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    targetCard
                    if let solution {
                        loadoutCard(solution)
                    }
                    Text("Plate sizes and counts are editable in Settings → Plates & Bars.")
                        .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Plate Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var targetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    FieldLabel("Target weight")
                    Spacer()
                    Text(displayUnit.suffix).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                }
                DarkTextField(text: $targetText, placeholder: displayUnit == .lb ? "e.g. 225" : "e.g. 100")
                    .keyboardType(.decimalPad)

                HStack {
                    Text("Bar").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Menu {
                        ForEach(PlateInventory.barOptions(unit: displayUnit), id: \.weight) { option in
                            Button("\(option.label) \(displayUnit.suffix)") {
                                inventory.barWeight = option.weight
                                PlateInventoryStore.save(inventory)
                            }
                        }
                    } label: {
                        Text("\(inventory.barWeight.formatted(.number.precision(.fractionLength(0...1)))) \(displayUnit.suffix)")
                            .font(.bodyStrong).foregroundStyle(theme.accent)
                    }
                }
            }
        }
    }

    private func loadoutCard(_ solution: PlateSolution) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Per side").font(.bodyStrong).foregroundStyle(theme.textSecondary)

                if solution.perSide.isEmpty {
                    Text("Just the bar.")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                } else {
                    WrapLayout(spacing: 8) {
                        ForEach(Array(solution.perSide.enumerated()), id: \.offset) { _, plate in
                            ForEach(0..<plate.count, id: \.self) { _ in
                                plateChip(plate.weight)
                            }
                        }
                    }
                }

                Divider().overlay(theme.separator)

                if solution.exact {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                        Text("Loads exactly \(Fmt.load(solution.achievedKg, unit: displayUnit)) \(displayUnit.suffix)")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warmup)
                            Text("Closest loadable: \(Fmt.load(solution.achievedKg, unit: displayUnit)) \(displayUnit.suffix)")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        }
                        Text("Your plates can't hit the exact target.")
                            .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    }
                }

                PrimaryButton(title: "Use \(Fmt.load(solution.achievedKg, unit: displayUnit)) \(displayUnit.suffix)") {
                    onApply(solution.achievedKg)
                    dismiss()
                }
            }
        }
    }

    /// A plate rendered as a weighted chip — bigger plates read heavier.
    private func plateChip(_ weight: Double) -> some View {
        PlateChip(weight: weight, unit: displayUnit)
    }
}

/// Shared plate chip (calculator + Settings editor).
struct PlateChip: View {
    @Environment(\.theme) private var theme
    let weight: Double
    let unit: WeightUnit

    var body: some View {
        let heavy = weight >= (unit == .lb ? 45 : 20)
        let medium = weight >= (unit == .lb ? 25 : 10)
        Text(weight.formatted(.number.precision(.fractionLength(0...2))))
            .font(.system(size: heavy ? 15 : 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: heavy ? 52 : (medium ? 44 : 38), height: heavy ? 52 : (medium ? 44 : 38))
            .background(
                Circle().fill(heavy ? theme.accent : (medium ? theme.accent.opacity(0.75) : theme.surfaceHighlight))
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 2))
    }
}

/// Settings editor for the plate inventory: bar weight + per-plate pair
/// steppers.
struct PlateInventoryEditor: View {
    @Environment(\.theme) private var theme
    let unit: WeightUnit
    @State private var inventory: PlateInventory

    init(unit: WeightUnit) {
        self.unit = unit
        _inventory = State(initialValue: PlateInventoryStore.load(unit: unit))
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack {
                    Text("Bar").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Menu {
                        ForEach(PlateInventory.barOptions(unit: unit), id: \.weight) { option in
                            Button("\(option.label) \(unit.suffix)") {
                                inventory.barWeight = option.weight
                                PlateInventoryStore.save(inventory)
                            }
                        }
                    } label: {
                        Text("\(inventory.barWeight.formatted(.number.precision(.fractionLength(0...1)))) \(unit.suffix)")
                            .font(.bodyStrong).foregroundStyle(theme.accent)
                    }
                }
                Divider().overlay(theme.separator)
                ForEach($inventory.plates) { $plate in
                    HStack(spacing: Space.md) {
                        PlateChip(weight: plate.weight, unit: unit)
                        Text("\(plate.weight.formatted(.number.precision(.fractionLength(0...2)))) \(unit.suffix)")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Stepper(value: $plate.pairs, in: 0...20) {
                            Text("\(plate.pairs) pairs")
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        }
                        .fixedSize()
                        .onChange(of: plate.pairs) { PlateInventoryStore.save(inventory) }
                    }
                }
                Button("Reset to standard") {
                    inventory = .standard(unit: unit)
                    PlateInventoryStore.save(inventory)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            }
        }
    }
}
