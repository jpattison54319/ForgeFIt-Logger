import ForgeCore
import ForgeData
import SwiftData
import SwiftUI

/// Sets a cardio effort's goal — one of three peer shapes rather than a single
/// "intervals" bucket: **Open** (just track), a **Zone lock** (hold one HR zone
/// the whole effort — a steady-state goal, the opposite of intervals), or
/// **Intervals** (warm-up → N × work/recover → cool-down with per-step zones and
/// auto-advancing cues). All three encode into the same `IntervalPlan`.
/// Closure-based so the routine editor (template) and the live cardio card (this
/// session) can both present it.
struct IntervalPlanBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    /// The goal shape being configured. Zone lock and intervals are distinct
    /// ways to pace an effort — steady vs structured — so they're peers here,
    /// not one nested inside the other.
    private enum GoalMode: String, CaseIterable, Identifiable {
        case open, zone, intervals
        var id: String { rawValue }
        var title: String {
            switch self {
            case .open: "Open"
            case .zone: "Zone lock"
            case .intervals: "Intervals"
            }
        }
        var blurb: String {
            switch self {
            case .open: "Just track time, distance, and heart rate — no target to hold."
            case .zone: "Hold one heart-rate zone the whole effort. Audible + haptic cue when you drift out."
            case .intervals: "Structured warm-up → work/recover rounds → cool-down, with auto-advancing cues."
            }
        }
    }

    /// User-saved presets (active only), newest first — rendered alongside the
    /// built-ins in the presets card.
    @Query(
        filter: #Predicate<IntervalPresetModel> { $0.deletedAt == nil },
        sort: \IntervalPresetModel.createdAt, order: .reverse
    ) private var userPresets: [IntervalPresetModel]

    private let onSave: (String?) -> Void

    @State private var warmup: Int
    @State private var repeats: Int
    @State private var work: Int
    @State private var recover: Int
    @State private var cooldown: Int
    @State private var mode: GoalMode
    /// 0 = no zone selected; 1...5 = target zone (used by the Zone lock mode).
    @State private var zoneTarget: Int
    /// Per-step zone targets for work/recover blocks (0 = none).
    @State private var workZone: Int
    @State private var recoverZone: Int

    /// "Save as preset" name-prompt state.
    @State private var showSavePrompt = false
    @State private var presetName = ""
    /// Presents the soft-delete management list for user presets.
    @State private var showManageSheet = false

    init(planJSON: String?, onSave: @escaping (String?) -> Void) {
        self.onSave = onSave
        let existing = IntervalPlan.decode(from: planJSON)
        // Derive the mode from the stored shape: steps win (intervals), else a
        // plan-wide zone means a lock, else it's open.
        let initialMode: GoalMode = {
            if existing?.hasSteps == true { return .intervals }
            if existing?.hrZoneTarget != nil { return .zone }
            return .open
        }()
        _mode = State(initialValue: initialMode)
        // Seed from the existing plan's shape, or sensible defaults.
        let work = existing?.steps.first { $0.kind == .work }
        let recover = existing?.steps.first { $0.kind == .recover }
        _warmup = State(initialValue: existing?.steps.first { $0.kind == .warmup }?.seconds ?? 300)
        _repeats = State(initialValue: existing.map { $0.steps.filter { $0.kind == .work }.count } ?? 6)
        _work = State(initialValue: work?.seconds ?? 60)
        _recover = State(initialValue: recover?.seconds ?? 90)
        _cooldown = State(initialValue: existing?.steps.first { $0.kind == .cooldown }?.seconds ?? 300)
        _zoneTarget = State(initialValue: existing?.hrZoneTarget ?? 0)
        _workZone = State(initialValue: work?.hrZone ?? 0)
        _recoverZone = State(initialValue: recover?.hrZone ?? 0)
    }

    /// Edit a routine exercise's stored template in place.
    init(routineExercise: RoutineExerciseModel) {
        self.init(planJSON: routineExercise.intervalPlanJSON) { json in
            routineExercise.intervalPlanJSON = json
            routineExercise.updatedAt = Date()
        }
    }

    private var plan: IntervalPlan {
        switch mode {
        case .open:
            return IntervalPlan(steps: [])
        case .zone:
            // Steady-state: a plan-wide zone lock, no steps.
            return IntervalPlan(steps: [], hrZoneTarget: zoneTarget == 0 ? nil : zoneTarget)
        case .intervals:
            // Structured: steps carry their own per-step zones; the plan-wide
            // lock stays off so the two goal shapes never blend.
            let steps = IntervalPlan.build(
                warmupSeconds: warmup, repeats: repeats,
                workSeconds: work, recoverSeconds: recover, cooldownSeconds: cooldown,
                workZone: workZone == 0 ? nil : workZone,
                recoverZone: recoverZone == 0 ? nil : recoverZone).steps
            return IntervalPlan(steps: steps, hrZoneTarget: nil)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    modeSelectorCard

                    switch mode {
                    case .open:
                        EmptyView()
                    case .zone:
                        zoneLockCard
                    case .intervals:
                        presetsCard
                        intervalStepsCard
                        totalCard
                    }
                }
                .padding(Space.lg)
                .animation(.spring(duration: 0.25), value: mode)
            }
            .background(theme.background)
            .navigationTitle("Cardio goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.font(.bodyStrong)
                }
            }
            .alert("Save preset", isPresented: $showSavePrompt) {
                TextField("Preset name", text: $presetName)
                Button("Cancel", role: .cancel) { presetName = "" }
                Button("Save") { saveAsPreset() }
            } message: {
                Text("Save this interval structure to reuse it later.")
            }
            .sheet(isPresented: $showManageSheet) {
                IntervalPresetManagerView()
            }
            // Entering Zone lock with nothing chosen? Seed Zone 2 — the
            // canonical steady-state base — so the goal is immediately valid.
            .onChange(of: mode) { _, newMode in
                if newMode == .zone, zoneTarget == 0 { zoneTarget = 2 }
            }
        }
    }

    /// The three peer goal shapes, with a one-line explanation of the selection.
    private var modeSelectorCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Picker("Goal", selection: $mode) {
                    ForEach(GoalMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("cardio-goal-mode")
                Text(mode.blurb)
                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Steady-state goal: pick one HR zone to hold for the whole effort.
    private var zoneLockCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("Target zone").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                HStack(spacing: Space.sm) {
                    ForEach(1...5, id: \.self) { z in
                        let selected = zoneTarget == z
                        Button {
                            zoneTarget = z
                        } label: {
                            Text("Z\(z)")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(selected ? Color.white : theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selected ? theme.zoneColor(z) : theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("zone-lock-\(z)")
                    }
                }
                if zoneTarget != 0 {
                    Text(HRZone.label(zoneTarget))
                        .font(.tag)
                        .foregroundStyle(theme.zoneColor(zoneTarget))
                }
            }
        }
    }

    /// Structured-interval builder: warm-up → rounds of work/recover → cool-down.
    private var intervalStepsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                durationRow("Warm-up", seconds: $warmup, step: 30)
                Divider().overlay(theme.separator)
                Stepper(value: $repeats, in: 1...30) {
                    HStack {
                        Text("Rounds").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(repeats)×").font(.bodyStrong).foregroundStyle(theme.secondaryAccent)
                    }
                }
                Divider().overlay(theme.separator)
                durationRow("Work", seconds: $work, step: 15, tint: theme.secondaryAccent)
                stepZoneRow("Work target zone", selection: $workZone)
                durationRow("Recover", seconds: $recover, step: 15)
                stepZoneRow("Recover target zone", selection: $recoverZone)
                Divider().overlay(theme.separator)
                durationRow("Cool-down", seconds: $cooldown, step: 30)
            }
        }
    }

    private var totalCard: some View {
        Card {
            HStack {
                Text("Total").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(Fmt.durationShort(plan.totalSeconds))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.secondaryAccent)
            }
        }
    }

    /// Quick-start templates: one tap fills the whole structure; the steppers
    /// stay editable after.
    private var presetsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("Presets").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                    Spacer()
                    Button("Save current") {
                        presetName = ""
                        showSavePrompt = true
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(plan.isMeaningful ? theme.secondaryAccent : theme.textTertiary)
                    .disabled(!plan.isMeaningful)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(IntervalPresets.builtIn, id: \.name) { preset in
                            presetChip(name: preset.name, plan: preset.plan, isUser: false) {
                                apply(preset.plan)
                            }
                        }
                        ForEach(userPresets) { preset in
                            if let plan = IntervalPlan.decode(from: preset.planJSON) {
                                presetChip(name: preset.name, plan: plan, isUser: true) {
                                    apply(plan)
                                }
                            }
                        }
                    }
                }
                if !userPresets.isEmpty {
                    Button("Manage saved presets") { showManageSheet = true }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func presetChip(name: String, plan: IntervalPlan, isUser: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isUser {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.secondaryAccent)
                    }
                    Text(name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(theme.textPrimary)
                }
                Text(plan.structureSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Seed the editor's steppers from a plan — used by both built-in and
    /// user-saved presets; the fields stay editable afterward.
    private func apply(_ plan: IntervalPlan) {
        let steps = plan.steps
        let workStep = steps.first { $0.kind == .work }
        let recoverStep = steps.first { $0.kind == .recover }
        warmup = steps.first { $0.kind == .warmup }?.seconds ?? 0
        repeats = max(1, steps.filter { $0.kind == .work }.count)
        work = workStep?.seconds ?? 60
        recover = recoverStep?.seconds ?? 60
        cooldown = steps.first { $0.kind == .cooldown }?.seconds ?? 0
        workZone = workStep?.hrZone ?? 0
        recoverZone = recoverStep?.hrZone ?? 0
        if let zone = plan.hrZoneTarget { zoneTarget = zone }
    }

    private func saveAsPreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        presetName = ""
        guard !trimmed.isEmpty, plan.isMeaningful, let json = plan.encodedJSON() else { return }
        let preset = IntervalPresetModel(userID: ForgeFitDemo.userID, name: trimmed, planJSON: json)
        modelContext.insert(preset)
        try? modelContext.save()
    }

    private func stepZoneRow(_ label: String, selection: Binding<Int>) -> some View {
        HStack {
            Text(label).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
            Spacer()
            Picker(label, selection: selection) {
                Text("None").tag(0)
                ForEach(1...5, id: \.self) { z in Text("Z\(z)").tag(z) }
            }
            .pickerStyle(.menu)
            .tint(selection.wrappedValue == 0 ? theme.textTertiary : theme.zoneColor(selection.wrappedValue))
        }
    }

    private func durationRow(_ label: String, seconds: Binding<Int>, step: Int, tint: Color? = nil) -> some View {
        Stepper(value: seconds, in: 0...3600, step: step) {
            HStack {
                Text(label).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                Spacer()
                Text(seconds.wrappedValue == 0 ? "Off" : Fmt.durationShort(seconds.wrappedValue))
                    .font(.bodyStrong).foregroundStyle(tint ?? theme.textPrimary)
            }
        }
    }

    private func save() {
        onSave(plan.isMeaningful ? plan.encodedJSON() : nil)
        dismiss()
    }
}

/// Built-in interval templates — the classics, ready in one tap.
enum IntervalPresets {
    struct Preset {
        let name: String
        let plan: IntervalPlan
    }

    static let builtIn: [Preset] = [
        Preset(name: "Run / Walk 10×1:00", plan: .build(
            warmupSeconds: 300, repeats: 10, workSeconds: 60, recoverSeconds: 60, cooldownSeconds: 300)),
        Preset(name: "Norwegian 4×4", plan: .build(
            warmupSeconds: 600, repeats: 4, workSeconds: 240, recoverSeconds: 180, cooldownSeconds: 300,
            workZone: 4, recoverZone: 3)),
        Preset(name: "30/30 HIIT", plan: .build(
            warmupSeconds: 300, repeats: 10, workSeconds: 30, recoverSeconds: 30, cooldownSeconds: 180)),
        Preset(name: "Sprint 8×0:20", plan: .build(
            warmupSeconds: 300, repeats: 8, workSeconds: 20, recoverSeconds: 100, cooldownSeconds: 300,
            workZone: 5)),
    ]
}

/// Soft-delete management list for the user's saved interval presets. Lives in
/// the builder sheet; removing a preset stamps `deletedAt` so it drops out of
/// the active query without a hard delete.
private struct IntervalPresetManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<IntervalPresetModel> { $0.deletedAt == nil },
        sort: \IntervalPresetModel.createdAt, order: .reverse
    ) private var presets: [IntervalPresetModel]

    var body: some View {
        NavigationStack {
            Group {
                if presets.isEmpty {
                    ContentUnavailableView(
                        "No saved presets",
                        systemImage: "bookmark",
                        description: Text("Save an interval structure from the builder to reuse it here.")
                    )
                } else {
                    List {
                        ForEach(presets) { preset in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name).font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                if let plan = IntervalPlan.decode(from: preset.planJSON) {
                                    Text(plan.structureSummary)
                                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                }
                            }
                            .listRowBackground(theme.surfaceElevated)
                        }
                        .onDelete(perform: delete)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(theme.background)
            .navigationTitle("Saved presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        let now = Date()
        for index in offsets {
            let preset = presets[index]
            preset.deletedAt = now
            preset.updatedAt = now
        }
        try? modelContext.save()
    }
}
