import ForgeCore
import SwiftUI

struct QuickIncrementSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var drafts = QuickIncrementKind.allCases.map { kind in
        QuickIncrementPreferences.load(kind).map {
            $0.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
        }
    }
    @FocusState private var focusedField: String?

    private func values(at index: Int) -> [Double]? {
        let parsed = drafts[index].compactMap(WeightInputParser.parse)
        return QuickIncrementKind.allCases[index].isValid(parsed) ? parsed : nil
    }

    private var canSave: Bool { drafts.indices.allSatisfy { values(at: $0) != nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text("Each amount is used for both + and − adjustments.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(QuickIncrementKind.allCases.enumerated()), id: \.element) { groupIndex, kind in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        Text(kind.title)
                            .font(.headline)
                            .foregroundStyle(theme.textPrimary)
                        Card {
                            VStack(spacing: Space.sm) {
                                ForEach(0..<3) { index in
                                    QuickIncrementAmountRow(
                                        kind: kind, index: index,
                                        text: $drafts[groupIndex][index], focus: $focusedField
                                    )
                                }
                            }
                        }
                        if values(at: groupIndex) == nil {
                            Label(kind.validationMessage, systemImage: "exclamationmark.circle")
                                .font(.subheadline)
                                .foregroundStyle(theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("quick-increment-\(kind.rawValue)-error")
                        }
                    }
                }

                Button("Reset to defaults", systemImage: "arrow.counterclockwise") {
                    focusedField = nil
                    drafts = QuickIncrementKind.allCases.map { $0.defaults.map {
                        $0.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
                    } }
                }
                .font(.body)
                .frame(minHeight: 44)
                .accessibilityIdentifier("quick-increment-reset")
            }
            .padding(Space.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(theme.background)
        .navigationTitle("Quick increments")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("quick-increment-save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
                    .accessibilityIdentifier("quick-increment-keyboard-done")
            }
        }
    }

    private func save() {
        guard canSave else { return }
        focusedField = nil
        for (index, kind) in QuickIncrementKind.allCases.enumerated() {
            if let values = values(at: index) { QuickIncrementPreferences.save(values, for: kind) }
        }
        dismiss()
    }
}
