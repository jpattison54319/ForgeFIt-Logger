import ForgeCore
import ForgeData
import SwiftUI

/// Shared wording for routine planning, live workout rows, VoiceOver, and the
/// Watch payload. Keeping it centralized prevents a percentage from reading
/// like a literal gym load on one surface and an adaptive rule on another.
@MainActor
enum LoadPrescriptionPresentation {
    static func percentInput(_ prescription: EstimatedOneRepMaxPrescription?) -> String {
        guard let prescription else { return "" }
        let low = number(prescription.lowPercent)
        guard let high = prescription.highPercent else { return low }
        return "\(low)–\(number(high))"
    }

    static func percentLabel(_ prescription: EstimatedOneRepMaxPrescription) -> String {
        "\(percentInput(prescription))% e1RM"
    }

    static func currentLoadLabel(
        for set: RoutineSetModel,
        exercise: ExerciseLibraryModel?,
        bestEstimatedOneRepMaxKg: Double?,
        unit: WeightUnit
    ) -> String? {
        guard set.loadPrescriptionMode == .percentEstimatedOneRepMax else { return nil }
        guard AdaptiveLoadResolver.supportsPercentagePrescription(exercise) else {
            return "Available for external strength loads only"
        }
        guard let prescription = set.estimatedOneRepMaxPrescription else {
            return "Enter 1–100% or a range"
        }
        guard let exercise, let baseline = bestEstimatedOneRepMaxKg,
              let raw = prescription.resolving(estimatedOneRepMaxKg: baseline) else {
            return "No estimated 1RM — load stays blank at start"
        }
        let low = AdaptiveLoadResolver.snap(raw.lowKg, for: exercise)
        let high = max(low, AdaptiveLoadResolver.snap(raw.highKg, for: exercise))
        return "Current: \(loadRange(low: low, high: high, unit: unit)) · best e1RM \(Fmt.loadUnit(baseline, unit: unit))"
    }

    static func routineLoadLabel(
        for set: RoutineSetModel,
        exercise: ExerciseLibraryModel?,
        bestEstimatedOneRepMaxKg: Double?,
        unit: WeightUnit
    ) -> String {
        guard set.loadPrescriptionMode == .percentEstimatedOneRepMax else {
            return Fmt.load(set.targetWeight, unit: unit)
        }
        guard let prescription = set.estimatedOneRepMaxPrescription else { return "% e1RM" }
        let percentage = percentLabel(prescription)
        guard let exercise, let baseline = bestEstimatedOneRepMaxKg,
              let raw = prescription.resolving(estimatedOneRepMaxKg: baseline) else {
            return percentage
        }
        let low = AdaptiveLoadResolver.snap(raw.lowKg, for: exercise)
        let high = max(low, AdaptiveLoadResolver.snap(raw.highKg, for: exercise))
        return "\(percentage) · \(loadRange(low: low, high: high, unit: unit))"
    }

    static func liveLabel(for set: SetModel, unit: WeightUnit) -> String? {
        guard set.loadPrescriptionMode == .percentEstimatedOneRepMax else { return nil }
        guard let prescription = set.estimatedOneRepMaxPrescription else {
            return "% e1RM · percentage not set — enter load"
        }
        let percentage = percentLabel(prescription)
        guard let low = set.prescribedLoadLowKg else {
            return "\(percentage) · no estimated 1RM — enter load"
        }
        let high = set.prescribedLoadHighKg ?? low
        let load = loadRange(low: low, high: high, unit: unit)
        if let baseline = set.prescribed1RMBaselineKg {
            return "\(percentage) · \(load) from \(Fmt.loadUnit(baseline, unit: unit)) e1RM"
        }
        return "\(percentage) · \(load)"
    }

    static func loadRange(low: Double, high: Double, unit: WeightUnit) -> String {
        if abs(low - high) < 0.000_1 {
            return Fmt.loadUnit(low, unit: unit)
        }
        return "\(Fmt.load(low, unit: unit))–\(Fmt.loadUnit(high, unit: unit))"
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

/// The routine set's load field and its visible basis selector. Fixed and
/// percentage values are preserved independently, so changing the selector is
/// reversible and never silently destroys an authored load.
struct RoutineLoadPrescriptionField: View {
    @Environment(\.theme) private var theme
    @Bindable var set: RoutineSetModel
    let unit: WeightUnit
    let supportsPercentage: Bool
    var supportsResistanceBands = false
    var onChange: () -> Void = {}

    @State private var draft = ""
    @State private var draftActive = false
    @State private var invalidDraft = false
    @FocusState private var focused: Bool

    private var isPercentage: Bool {
        self.set.loadPrescriptionMode == .percentEstimatedOneRepMax
    }

    /// An imported prescription can outlive a later exercise-mode change.
    /// Keep its selector visible so the user has an obvious route back to a
    /// fixed load instead of hiding active plan semantics.
    private var showsBasisSelector: Bool { supportsPercentage || isPercentage }

    var body: some View {
        HStack(spacing: 0) {
            if supportsResistanceBands && !isPercentage {
                ResistanceBandLoadMenu(
                    selectedWeightKilograms: set.targetWeight,
                    unit: unit,
                    onSelect: selectBand
                )
            }

            TextField(fieldPlaceholder, text: textBinding)
                .focused($focused)
                .keyboardType(isPercentage ? .numbersAndPunctuation : .decimalPad)
                .font(.bodyStrong)
                .multilineTextAlignment(supportsResistanceBands && !isPercentage ? .trailing : .center)
                .padding(.horizontal, 4)
                .foregroundStyle(theme.textPrimary)
                .accessibilityLabel(isPercentage ? "Percentage of estimated one rep max" : "Fixed load")
                .accessibilityIdentifier("routine-set-load-value-\(set.id.uuidString)")

            if showsBasisSelector {
                Rectangle()
                    .fill(theme.separator)
                    .frame(width: 1, height: 24)

                ScrollSafeMenu(sections: [[
                    ScrollSafeMenuItem(title: "Fixed load", isChecked: !isPercentage) {
                        selectMode(.fixed)
                    },
                    ScrollSafeMenuItem(
                        title: "% estimated 1RM",
                        isChecked: isPercentage,
                        isDisabled: !supportsPercentage
                    ) {
                        selectMode(.percentEstimatedOneRepMax)
                    }
                ]]) {
                    HStack(spacing: 3) {
                        Text(isPercentage ? "%" : unit.shortSuffix)
                            .font(.system(size: 11, weight: .bold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(theme.accentForeground)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Load basis")
                .accessibilityValue(isPercentage ? "Percent estimated one rep max" : "Fixed load")
                .accessibilityIdentifier("routine-set-load-basis-\(set.id.uuidString)")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if invalidDraft {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.danger, lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                draftActive = false
                invalidDraft = false
            }
        }
        .onChange(of: set.loadPrescriptionModeRaw) { _, _ in
            focused = false
            draftActive = false
            invalidDraft = false
        }
    }

    private var fieldPlaceholder: String {
        isPercentage ? "82.5 or 67–72" : unit.suffix
    }

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if focused && draftActive { return draft }
                if isPercentage {
                    return LoadPrescriptionPresentation.percentInput(set.estimatedOneRepMaxPrescription)
                }
                return set.targetWeight.map { Fmt.load($0, unit: unit) } ?? ""
            },
            set: updateText
        )
    }

    private func updateText(_ text: String) {
        draft = text
        draftActive = true
        if isPercentage {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                set.target1RMPercentLow = nil
                set.target1RMPercentHigh = nil
                invalidDraft = false
                onChange()
                return
            }
            guard let prescription = EstimatedOneRepMaxPrescription.parse(text) else {
                invalidDraft = true
                return
            }
            set.target1RMPercentLow = prescription.lowPercent
            set.target1RMPercentHigh = prescription.highPercent
            invalidDraft = false
        } else {
            set.targetWeight = Fmt.loadKilograms(from: text, unit: unit)
            invalidDraft = false
        }
        onChange()
    }

    private func selectMode(_ mode: LoadPrescriptionMode) {
        guard mode == .fixed || supportsPercentage else { return }
        set.loadPrescriptionMode = mode
        onChange()
    }

    private func selectBand(_ kilograms: Double) {
        focused = false
        draftActive = false
        set.targetWeight = kilograms
        onChange()
    }
}

/// Compact persistent context below a live set. It stays visible after the
/// athlete edits the concrete load so the rule and today's resolved range are
/// never confused with the number actually performed.
struct LiveLoadPrescriptionStrip: View {
    @Environment(\.theme) private var theme
    let set: SetModel
    let unit: WeightUnit

    var body: some View {
        if let label = LoadPrescriptionPresentation.liveLabel(for: set, unit: unit) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "percent")
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(set.prescribed1RMBaselineKg == nil ? theme.warmup : theme.accentForeground)
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(theme.surfaceElevated.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Adaptive load: \(label)")
            .accessibilityIdentifier("live-load-prescription-\(set.id.uuidString)")
        }
    }
}
