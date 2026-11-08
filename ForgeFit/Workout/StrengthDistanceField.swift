import ForgeCore
import SwiftUI

struct StrengthDistanceField: View {
    @Environment(\.theme) private var theme
    @AppStorage(StrengthDistanceUnit.preferenceKey) private var unit: StrengthDistanceUnit = .meters
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var draftEdited = false
    @State private var draftUnit: StrengthDistanceUnit = .meters

    let meters: Double?
    let token: UUID
    let focusRequest: Int
    let isEditable: Bool
    let pendingDrafts: PendingDraftCoordinator
    let onSave: (Double?) -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            TextField("Distance", text: Binding(get: { draft }, set: {
                draft = $0
                if !draftEdited { draftUnit = unit }
                draftEdited = true
            }))
                .font(.bodyStrong.monospacedDigit())
                .keyboardType(.decimalPad)
                .focused($focused)
                .disabled(!isEditable)
                .padding(.leading, Space.sm)
                .frame(minHeight: TouchTarget.minimum)
                .accessibilityLabel("Distance in \(unit.title.lowercased())")
                .accessibilityIdentifier("strength-distance-value")
            ScrollSafeMenu(sections: [StrengthDistanceUnit.allCases.map { choice in
                ScrollSafeMenuItem(title: choice.title, isChecked: choice == unit) { select(choice) }
            }]) {
                HStack(spacing: Space.xs) {
                    Text(unit.rawValue).font(.bodyStrong)
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(theme.accentForeground)
                .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
                .contentShape(.rect)
            }
            .accessibilityLabel("Distance unit")
            .accessibilityValue(unit.title)
            .accessibilityIdentifier("strength-distance-unit")
        }
        .background(theme.surfaceElevated, in: .rect(cornerRadius: Radius.control))
        .onChange(of: meters, initial: true) { _, _ in
            if !focused { draft = formatted(meters, in: unit) }
        }
        .onChange(of: unit) { _, _ in
            let saved = commit()
            focused = false
            draft = formatted(saved, in: unit)
        }
        .onChange(of: focusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { _ = commit() }
        }
        .onAppear { pendingDrafts.register(token, commit: { _ = commit() }) }
        .onDisappear {
            _ = commit()
            pendingDrafts.unregister(token)
        }
    }

    private func formatted(_ meters: Double?, in unit: StrengthDistanceUnit) -> String {
        meters.map { unit.number(meters: $0) } ?? ""
    }

    @discardableResult
    private func commit() -> Double? {
        guard draftEdited else { return meters }
        draftEdited = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            onSave(nil)
            return nil
        }
        let normalized = text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized),
              let next = StrengthDistanceUnit.validMeters(draftUnit.meters(from: value)) else {
            draft = formatted(meters, in: unit)
            return meters
        }
        onSave(next)
        return next
    }

    private func select(_ choice: StrengthDistanceUnit) {
        guard choice != unit else { return }
        let saved = commit()
        focused = false
        unit = choice
        draft = formatted(saved, in: choice)
    }
}
