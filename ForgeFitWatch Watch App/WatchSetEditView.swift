import SwiftUI
import WatchKit
import ForgeCore

/// Minimal one-screen set editor for the wrist: pick weight or reps, turn the
/// digital crown (or tap ±), Done commits a single update to the phone.
/// No keyboards, no set types — everything else stays on the iPhone.
struct WatchSetEditView: View {
    @Environment(\.dismiss) private var dismiss

    let store: WatchStore
    let exercise: WatchExerciseSnapshot
    let set: WatchSetSnapshot

    private enum Field { case weight, reps }
    @State private var field: Field = .weight
    /// Weight edited in kg internally; stepped and shown in the display unit.
    @State private var weightKg: Double
    @State private var reps: Int
    @State private var crown: Double = 0
    @State private var lastCrownStep = 0

    private let unitSuffix: String
    private var isKg: Bool { unitSuffix == "kg" }
    private static let lbPerKg = 2.2046226218
    /// 2.5 kg or 5 lb per crown detent / tap.
    private var stepKg: Double { isKg ? 2.5 : 5 / Self.lbPerKg }
    private var displayWeight: Double {
        isKg ? weightKg : weightKg * Self.lbPerKg
    }

    init(store: WatchStore, exercise: WatchExerciseSnapshot, set: WatchSetSnapshot) {
        self.store = store
        self.exercise = exercise
        self.set = set
        self.unitSuffix = set.unitSuffix ?? store.context?.unitSuffix ?? "lb"
        _weightKg = State(initialValue: set.weightKg ?? 0)
        _reps = State(initialValue: set.reps ?? 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(exercise.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                valueTile(
                    label: unitSuffix,
                    value: WFmt.weight(displayWeight),
                    selected: field == .weight,
                    tint: WTheme.accent
                ) { field = .weight }
                valueTile(
                    label: "reps",
                    value: "\(reps)",
                    selected: field == .reps,
                    tint: WTheme.teal
                ) { field = .reps }
            }

            HStack(spacing: 10) {
                stepButton("minus") { adjust(-1) }
                stepButton("plus") { adjust(1) }
            }

            Button {
                store.updateSet(set, in: exercise, weightKg: weightKg > 0 ? weightKg : nil, reps: reps > 0 ? reps : nil)
                dismiss()
            } label: {
                Text("Done").font(.system(size: 15, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(WTheme.accent)
        }
        .padding(.horizontal, 4)
        // The crown drives the focused value: one detent unit = one step.
        .focusable(true)
        .digitalCrownRotation($crown, from: -1000, through: 1000, by: 1, sensitivity: .low, isContinuous: false)
        .onChange(of: crown) { _, newValue in
            let step = Int(newValue.rounded())
            let delta = step - lastCrownStep
            if delta != 0 {
                adjust(delta)
                lastCrownStep = step
            }
        }
    }

    private func adjust(_ steps: Int) {
        switch field {
        case .weight:
            weightKg = max(0, weightKg + Double(steps) * stepKg)
        case .reps:
            reps = max(0, reps + steps)
        }
        WKInterfaceDevice.current().play(.click)
    }

    private func valueTile(label: String, value: String, selected: Bool, tint: Color, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? tint : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? tint : .clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .tint(WTheme.surface)
        .buttonStyle(.borderedProminent)
    }
}
