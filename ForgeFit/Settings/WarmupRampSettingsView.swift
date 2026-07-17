import ForgeCore
import SwiftUI

/// Configure the default warm-up ramp the live logger inserts on "Add Warm-up
/// Ramp": how many warm-up sets, each set's weight as a percentage of the first
/// working set, and its reps. Weights are decided from the working set at
/// logging time; reps are fixed here. Persists via `WarmupRampConfigStore`.
struct WarmupRampSettingsView: View {
    @Environment(\.theme) private var theme
    @State private var config = WarmupRampConfigStore.load()

    private var unit: WeightUnit { Fmt.unit }
    /// Illustrative working weight for the preview, in the display unit.
    private let previewTop: Double = 100
    private var step: Double { unit == .lb ? 5 : 2.5 }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Space.xl) {
                explainerCard
                setsCard
                previewCard
                if !config.isDefault {
                    SecondaryButton(title: "Reset to default ramp", systemImage: "arrow.uturn.backward") {
                        config = WarmupRampConfig()
                    }
                }
            }
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.lg)
        }
        .background(theme.background)
        .navigationTitle("Warm-up ramp")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: config) { _, _ in WarmupRampConfigStore.save(config) }
    }

    // MARK: - Explainer

    private var explainerCard: some View {
        Card {
            Text("Warm-up weights use your first working set. Reps use the configured values.")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sets editor

    private var setsCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Warm-up sets")
            Card {
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach(config.stages.indices, id: \.self) { index in
                        stageEditor(index)
                        if index < config.stages.count - 1 {
                            Divider().overlay(theme.separator)
                        }
                    }
                    if config.stages.count < WarmupRampConfig.maxStages {
                        Divider().overlay(theme.separator)
                        Button(action: addStage) {
                            Label("Add warm-up set", systemImage: "plus.circle.fill")
                                .font(.bodyStrong)
                                .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("add-warmup-stage")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stageEditor(_ index: Int) -> some View {
        // Read the stage once, guarded: rows are removable, so an index can go
        // stale for a render. Display uses the local copy; edits go through the
        // range-checked bindings.
        if config.stages.indices.contains(index) {
            let stage = config.stages[index]
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("Warm-up \(index + 1)")
                        .font(.bodyStrong)
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    if config.stages.count > 1 {
                        Button {
                            removeStage(index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove warm-up \(index + 1)")
                    }
                }
                Stepper(value: weightBinding(index), in: 5...95, step: 5) {
                    HStack {
                        Text("Weight").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("\(stage.weightPercent)% of working")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
                Stepper(value: repsBinding(index), in: 1...30) {
                    HStack {
                        Text("Reps").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("\(stage.reps)")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                    }
                }
            }
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            SectionHeader("Preview")
            Card {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("A 100 \(unit.suffix) working set would warm up:")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                    ForEach(config.stages.indices, id: \.self) { index in
                        HStack(spacing: Space.md) {
                            Text("\(config.stages[index].weightPercent)%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.warmup)
                                .frame(width: 40, alignment: .leading)
                            Text(previewLine(index))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Bindings & mutations

    private func weightBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { config.stages.indices.contains(index) ? config.stages[index].weightPercent : 40 },
            set: { if config.stages.indices.contains(index) { config.stages[index].weightPercent = min(95, max(5, $0)) } }
        )
    }

    private func repsBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { config.stages.indices.contains(index) ? config.stages[index].reps : 10 },
            set: { if config.stages.indices.contains(index) { config.stages[index].reps = min(30, max(1, $0)) } }
        )
    }

    private func addStage() {
        // Continue the ramp: a step heavier than the last set, same reps.
        let last = config.stages.last
        let nextPercent = min(95, (last?.weightPercent ?? 60) + 10)
        config.stages.append(.init(weightPercent: nextPercent, reps: last?.reps ?? 3))
    }

    private func removeStage(_ index: Int) {
        guard config.stages.count > 1, config.stages.indices.contains(index) else { return }
        config.stages.remove(at: index)
    }

    /// Display-unit weight (already in the working-set's unit — not kg — so it
    /// is formatted directly, never through `Fmt.load`'s kg conversion).
    private func previewLine(_ index: Int) -> String {
        guard config.stages.indices.contains(index) else { return "" }
        let weight = config.weight(forStageAt: index, topWeightInDisplayUnit: previewTop, step: step) ?? 0
        let reps = config.stages[index].reps
        let weightStr = weight == weight.rounded() ? String(Int(weight)) : String(format: "%.1f", weight)
        return "\(weightStr) \(unit.suffix) × \(reps)"
    }
}
