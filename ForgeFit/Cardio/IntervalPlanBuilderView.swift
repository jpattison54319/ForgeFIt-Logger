import ForgeCore
import ForgeData
import SwiftUI

/// Builds a time-based interval template for a routine's cardio exercise:
/// warmup → N × (work / recover) → cooldown, with a live total-duration
/// readout. Persists to `RoutineExerciseModel.intervalPlanJSON`.
struct IntervalPlanBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var routineExercise: RoutineExerciseModel

    @State private var warmup: Int
    @State private var repeats: Int
    @State private var work: Int
    @State private var recover: Int
    @State private var cooldown: Int
    @State private var enabled: Bool
    /// 0 = no zone lock; 1...5 = target zone.
    @State private var zoneTarget: Int

    init(routineExercise: RoutineExerciseModel) {
        self.routineExercise = routineExercise
        let existing = IntervalPlan.decode(from: routineExercise.intervalPlanJSON)
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
    }

    private var plan: IntervalPlan {
        let steps = enabled
            ? IntervalPlan.build(warmupSeconds: warmup, repeats: repeats,
                                 workSeconds: work, recoverSeconds: recover, cooldownSeconds: cooldown).steps
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
                                durationRow("Recover", seconds: $recover, step: 15)
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
                                    .font(.system(size: 12, weight: .semibold))
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
        routineExercise.intervalPlanJSON = plan.isMeaningful ? plan.encodedJSON() : nil
        routineExercise.updatedAt = Date()
        dismiss()
    }
}
