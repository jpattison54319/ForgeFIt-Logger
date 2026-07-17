import ForgeCore
import SwiftUI

extension YogaPoseCatalog {
    /// Catalog poses in the shape the pure generator consumes. Poses missing
    /// a category or with an unknown difficulty are skipped — the generator
    /// would rather work from fewer poses than sequence one it can't place.
    static func generatorInputs() -> [YogaFlowGenerator.PoseInput] {
        load().compactMap { seed in
            guard let raw = seed.category,
                  let category = YogaFlowGenerator.Category(rawValue: raw),
                  let difficulty = YogaFlowGenerator.Difficulty(rawValue: seed.difficulty) else { return nil }
            return YogaFlowGenerator.PoseInput(
                slug: seed.slug,
                poseID: id(forSlug: seed.slug),
                name: seed.name,
                category: category,
                difficulty: difficulty,
                unilateral: seed.unilateral,
                defaultHoldSeconds: seed.defaultHoldSeconds
            )
        }
    }
}

/// 2E: pick a style, length, and level — get a properly sequenced class
/// (warm-up → standing build → peak → floor unwind → savasana) from the
/// authored pose catalog. Shuffle regenerates with a new seed; the result
/// lands in the flow builder where it can be tweaked, saved, or attached
/// like any hand-built flow.
struct YogaFlowGeneratorSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let onGenerated: (YogaFlowPlan) -> Void

    @State private var style: YogaStyle = .vinyasa
    @State private var minutes = 20
    @State private var difficulty: YogaFlowGenerator.Difficulty = .beginner
    @State private var seed = UInt64.random(in: 0...UInt64.max)

    private static let minuteOptions = [10, 15, 20, 30, 45, 60]

    private var plan: YogaFlowPlan? {
        YogaFlowGenerator.generate(
            request: .init(style: style, targetMinutes: minutes, difficulty: difficulty, seed: seed),
            poses: YogaPoseCatalog.generatorInputs()
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Style", selection: $style) {
                        ForEach(YogaStyle.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Picker("Length", selection: $minutes) {
                        ForEach(Self.minuteOptions, id: \.self) { option in
                            Text("\(option) min").tag(option)
                        }
                    }
                    Picker("Level", selection: $difficulty) {
                        Text("Beginner").tag(YogaFlowGenerator.Difficulty.beginner)
                        Text("Intermediate").tag(YogaFlowGenerator.Difficulty.intermediate)
                        Text("Advanced").tag(YogaFlowGenerator.Difficulty.advanced)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(theme.surface)

                if let plan {
                    Section("Preview — \(plan.structureSummary)") {
                        ForEach(plan.steps) { step in
                            HStack {
                                Text(step.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(step.side == .bothSides ? "\(step.holdSeconds)s × 2" : "\(step.holdSeconds)s")
                                    .font(.system(size: 13, design: .rounded)).foregroundStyle(theme.textSecondary)
                            }
                        }
                        Button {
                            seed = UInt64.random(in: 0...UInt64.max)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                        }
                    }
                    .listRowBackground(theme.surface)
                } else {
                    Section {
                        Text("Not enough poses at this level for a \(minutes)-minute \(style.title) class — try a longer level range or shorter class.")
                            .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    }
                    .listRowBackground(theme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Generate a Class")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Flow") {
                        if let plan { onGenerated(plan) }
                        dismiss()
                    }
                    .disabled(plan == nil)
                }
            }
        }
    }
}
