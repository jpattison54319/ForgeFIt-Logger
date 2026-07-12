import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Build or edit a guided yoga sequence: ordered pose holds with per-step
/// hold length and side handling, a style, and one-tap loading of built-in
/// classes or saved flows. Mirrors `IntervalPlanBuilderView`'s contract —
/// closure-based, hands back encoded JSON on save, touches nothing until then.
struct YogaFlowBuilderView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExerciseLibraryModel.name) private var exercises: [ExerciseLibraryModel]
    @Query(filter: #Predicate<YogaFlowModel> { $0.deletedAt == nil }, sort: \YogaFlowModel.position)
    private var savedFlows: [YogaFlowModel]

    let onSave: (String?) -> Void

    @State private var style: YogaStyle
    @State private var steps: [YogaFlowPlan.PoseStep]
    @State private var showPosePicker = false
    @State private var showSaveAsFlow = false
    @State private var newFlowName = ""

    init(planJSON: String?, onSave: @escaping (String?) -> Void) {
        self.onSave = onSave
        let plan = YogaFlowPlan.decode(from: planJSON)
        _style = State(initialValue: plan?.style ?? .hatha)
        _steps = State(initialValue: plan?.steps ?? [])
    }

    private var plan: YogaFlowPlan {
        YogaFlowPlan(style: style, steps: steps)
    }

    var body: some View {
        NavigationStack {
            List {
                styleSection
                stepsSection
                loadSection
            }
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .navigationTitle("Yoga Flow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(steps.isEmpty ? nil : plan.encodedJSON())
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showPosePicker) {
                ExercisePickerView(presetModality: .yoga) { picked in
                    for exercise in picked where exercise.isYoga {
                        steps.append(YogaFlowPlan.PoseStep(
                            poseID: exercise.id,
                            poseSlug: YogaPoseCatalog.slug(for: exercise),
                            name: exercise.name,
                            holdSeconds: exercise.defaultHoldSeconds ?? 30,
                            side: exercise.isUnilateral ? .bothSides : nil
                        ))
                    }
                }
            }
            .alert("Save as My Flow", isPresented: $showSaveAsFlow) {
                TextField("Flow name", text: $newFlowName)
                Button("Save") { saveAsUserFlow() }
                Button("Cancel", role: .cancel) { newFlowName = "" }
            } message: {
                Text("Saves this sequence for reuse from any routine or quick start.")
            }
        }
    }

    private var styleSection: some View {
        Section {
            HStack {
                Text("Style").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Menu {
                    ForEach(YogaStyle.allCases, id: \.self) { option in
                        Button {
                            style = option
                        } label: {
                            Label("\(option.title) — \(option.blurb)", systemImage: option.systemImage)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: style.systemImage).font(.system(size: 13, weight: .semibold))
                        Text(style.title).font(.bodyStrong)
                    }
                    .foregroundStyle(theme.accent)
                }
            }
            .listRowBackground(theme.surface)
            if style.isRestorative {
                Text("Restorative styles count as recovery, not training strain.")
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .listRowBackground(theme.surface)
            }
        } footer: {
            Text(plan.hasSteps ? "Total: \(plan.structureSummary)" : "Add poses to build the sequence.")
        }
    }

    private var stepsSection: some View {
        Section("Poses") {
            ForEach($steps) { $step in
                PoseStepRow(step: $step, isUnilateral: isUnilateral(step))
                    .listRowBackground(theme.surface)
            }
            .onDelete { steps.remove(atOffsets: $0) }
            .onMove { steps.move(fromOffsets: $0, toOffset: $1) }

            Button {
                showPosePicker = true
            } label: {
                Label("Add Pose", systemImage: "plus.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.accent)
            }
            .listRowBackground(theme.surface)
            .accessibilityIdentifier("add-pose-to-flow")
        }
    }

    private var loadSection: some View {
        Section("Start From") {
            Menu {
                ForEach(YogaFlowCatalog.load(), id: \.slug) { seed in
                    Button {
                        load(YogaFlowCatalog.plan(for: seed))
                    } label: {
                        Label(seed.name, systemImage: seed.style.systemImage)
                    }
                }
            } label: {
                Label("Built-in classes", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
            }
            .listRowBackground(theme.surface)

            if !savedFlows.isEmpty {
                Menu {
                    ForEach(savedFlows) { flow in
                        Button(flow.name) {
                            if let saved = flow.plan { load(saved) }
                        }
                    }
                } label: {
                    Label("My flows", systemImage: "bookmark")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                }
                .listRowBackground(theme.surface)
            }

            if !steps.isEmpty {
                Button {
                    newFlowName = ""
                    showSaveAsFlow = true
                } label: {
                    Label("Save as My Flow…", systemImage: "bookmark.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.accent)
                }
                .listRowBackground(theme.surface)
            }
        }
    }

    /// Loading a template value-copies its steps with FRESH step IDs so two
    /// attachments of one flow never share identity.
    private func load(_ template: YogaFlowPlan) {
        style = template.style
        steps = template.steps.map { step in
            YogaFlowPlan.PoseStep(
                poseID: step.poseID,
                poseSlug: step.poseSlug,
                name: step.name,
                holdSeconds: step.holdSeconds,
                side: step.side,
                transitionCue: step.transitionCue
            )
        }
    }

    private func saveAsUserFlow() {
        let trimmed = newFlowName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let json = plan.encodedJSON() else { return }
        modelContext.insert(YogaFlowModel(
            userID: ForgeFitDemo.userID,
            name: trimmed,
            styleRaw: style.rawValue,
            planJSON: json,
            position: (savedFlows.map(\.position).max() ?? -1) + 1
        ))
        try? modelContext.save()
        newFlowName = ""
    }

    private func isUnilateral(_ step: YogaFlowPlan.PoseStep) -> Bool {
        if let pose = YogaPoseCatalog.pose(forSlug: step.poseSlug) { return pose.unilateral }
        return exercises.first { $0.id == step.poseID }?.isUnilateral ?? (step.side != nil)
    }
}

/// One editable hold: art, name, hold-length menu, and side handling for
/// one-sided poses.
private struct PoseStepRow: View {
    @Environment(\.theme) private var theme
    @Binding var step: YogaFlowPlan.PoseStep
    let isUnilateral: Bool

    private static let holdOptions = [10, 15, 20, 30, 45, 60, 90, 120, 150, 180]

    var body: some View {
        HStack(spacing: Space.md) {
            YogaPoseArt(slug: step.poseSlug, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                if isUnilateral {
                    Menu {
                        Button("Both sides") { step.side = .bothSides }
                        Button("Left only") { step.side = .left }
                        Button("Right only") { step.side = .right }
                    } label: {
                        Text(sideLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            Spacer()
            Menu {
                ForEach(Self.holdOptions, id: \.self) { seconds in
                    Button(Fmt.restTimer(seconds)) { step.holdSeconds = seconds }
                }
            } label: {
                Text(Fmt.restTimer(step.holdSeconds))
                    .font(.system(size: 15, weight: .bold)).monospacedDigit()
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(theme.accentSoft)
                    .clipShape(Capsule())
            }
        }
    }

    private var sideLabel: String {
        switch step.side {
        case .bothSides, nil: "Both sides"
        case .left: "Left only"
        case .right: "Right only"
        }
    }
}
