import ForgeCore
import ForgeData
import SwiftUI

/// Builds a time-based interval template for a cardio exercise: warmup →
/// N × (work / recover) → cooldown, optional per-step HR zone targets, and a
/// plan-wide zone lock — with a live total-duration readout. Closure-based so
/// the routine editor (template) and the live cardio card (this session) can
/// both present it.
struct IntervalPlanBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private let onSave: (String?) -> Void

    @State private var warmup: Int
    @State private var repeats: Int
    @State private var work: Int
    @State private var recover: Int
    @State private var cooldown: Int
    @State private var enabled: Bool
    /// 0 = no zone lock; 1...5 = target zone.
    @State private var zoneTarget: Int
    /// Per-step zone targets for work/recover blocks (0 = none).
    @State private var workZone: Int
    @State private var recoverZone: Int

    init(planJSON: String?, onSave: @escaping (String?) -> Void) {
        self.onSave = onSave
        let existing = IntervalPlan.decode(from: planJSON)
        _enabled = State(initialValue: existing?.hasSteps ?? false)
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
        let steps = enabled
            ? IntervalPlan.build(
                warmupSeconds: warmup, repeats: repeats,
                workSeconds: work, recoverSeconds: recover, cooldownSeconds: cooldown,
                workZone: workZone == 0 ? nil : workZone,
                recoverZone: recoverZone == 0 ? nil : recoverZone).steps
            : []
        return IntervalPlan(steps: steps, hrZoneTarget: zoneTarget == 0 ? nil : zoneTarget)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Card {
                        Toggle(isOn: $enabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Structured intervals").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                Text("Auto-advancing work/recover blocks with cues.")
                                    .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                            }
                        }
                        .tint(theme.secondaryAccent)
                    }

                    if enabled {
                        presetsCard

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

                        Card {
                            HStack {
                                Text("Total").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Text(Fmt.durationShort(plan.totalSeconds))
                                    .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.secondaryAccent)
                            }
                        }
                    }

                    // Zone lock — independent of time intervals.
                    Card {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Zone lock").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                                    Text("Audible + haptic cue when you leave or re-enter the zone.")
                                        .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: Space.sm)
                                Picker("Target zone", selection: $zoneTarget) {
                                    Text("Off").tag(0)
                                    ForEach(1...5, id: \.self) { z in Text("Z\(z)").tag(z) }
                                }
                                .pickerStyle(.menu)
                                .tint(theme.secondaryAccent)
                            }
                            if zoneTarget != 0 {
                                Text(HRZone.label(zoneTarget))
                                    .font(.tag)
                                    .foregroundStyle(theme.zoneColor(zoneTarget))
                            }
                        }
                    }
                }
                .padding(Space.lg)
            }
            .background(theme.background)
            .navigationTitle("Intervals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.font(.bodyStrong)
                }
            }
        }
    }

    /// Quick-start templates: one tap fills the whole structure; the steppers
    /// stay editable after.
    private var presetsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Presets").font(.bodyStrong).foregroundStyle(theme.textPrimary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.sm) {
                        ForEach(IntervalPresets.builtIn, id: \.name) { preset in
                            Button {
                                load(preset)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.textPrimary)
                                    Text(preset.plan.structureSummary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(theme.surfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func load(_ preset: IntervalPresets.Preset) {
        let steps = preset.plan.steps
        let workStep = steps.first { $0.kind == .work }
        let recoverStep = steps.first { $0.kind == .recover }
        warmup = steps.first { $0.kind == .warmup }?.seconds ?? 0
        repeats = max(1, steps.filter { $0.kind == .work }.count)
        work = workStep?.seconds ?? 60
        recover = recoverStep?.seconds ?? 60
        cooldown = steps.first { $0.kind == .cooldown }?.seconds ?? 0
        workZone = workStep?.hrZone ?? 0
        recoverZone = recoverStep?.hrZone ?? 0
        if let zone = preset.plan.hrZoneTarget { zoneTarget = zone }
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
