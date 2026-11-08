import ForgeCore
import SwiftUI

struct StrengthSetLoadField: View {
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var isEdited = false
    let weight: Double?
    let unit: WeightUnit
    let supportsResistanceBands: Bool
    var compact = false
    let pendingDrafts: PendingDraftCoordinator
    let setID: UUID
    let onSave: (Double?) -> Void

    var body: some View {
        HStack(spacing: compact ? ResistanceBandLoadMenu.fieldSpacing : Space.sm) {
            if supportsResistanceBands {
                ResistanceBandLoadMenu(selectedWeightKilograms: weight, unit: unit) { selected in
                    isEdited = false
                    draft = Fmt.load(selected, unit: unit)
                    focused = false
                    onSave(selected)
                }
            }
            TextField(placeholder, text: Binding(get: { draft }, set: {
                draft = $0
                isEdited = true
            }))
                .keyboardType(.decimalPad)
                .focused($focused)
                .multilineTextAlignment(compact ? .center : .trailing)
                .font(.bodyStrong)
                .textFieldStyle(.plain)
                .frame(minHeight: TouchTarget.minimum)
                .accessibilityLabel("Set load in \(unit.suffix)")
                .accessibilityIdentifier("strength-set-load")
        }
        .padding(.leading, compact ? 0 : Space.sm)
        .padding(.trailing, compact ? Space.xs : Space.sm)
        .background(theme.surfaceElevated, in: .rect(cornerRadius: compact ? 8 : Radius.control))
        .onChange(of: weight, initial: true) { _, _ in
            if !focused { draft = weight.map { Fmt.load($0, unit: unit) } ?? "" }
        }
        .onChange(of: unit) { _, _ in
            if !focused { draft = weight.map { Fmt.load($0, unit: unit) } ?? "" }
        }
        .onChange(of: focused) { _, focused in if !focused { commit() } }
        .onAppear { pendingDrafts.register(setID, commit: commit) }
        .onDisappear {
            commit()
            pendingDrafts.unregister(setID)
        }
    }

    private var placeholder: String {
        if compact { return "—" }
        return supportsResistanceBands ? unit.suffix : "Load (\(unit.suffix))"
    }

    private func commit() {
        guard isEdited else { return }
        isEdited = false
        let formatted = weight.map { Fmt.load($0, unit: unit) } ?? ""
        guard draft != formatted else { return }
        let value = Fmt.loadKilograms(from: draft, unit: unit)
        guard draft.isEmpty || value != nil else {
            draft = formatted
            return
        }
        onSave(value)
    }
}
