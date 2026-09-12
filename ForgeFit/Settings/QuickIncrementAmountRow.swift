import SwiftUI

struct QuickIncrementAmountRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let kind: QuickIncrementKind
    let index: Int
    @Binding var text: String
    let focus: FocusState<String?>.Binding

    private var title: String { ["Small", "Medium", "Large"][index] }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(spacing: Space.md))
        layout {
            Text(title)
                .font(.body)
                .foregroundStyle(theme.textSecondary)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Space.sm) }
            HStack(spacing: Space.xs) {
                Text("±")
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
                TextField("Amount", text: $text)
                    .keyboardType(kind == .reps ? .numberPad : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused(focus, equals: kind.key(index))
                    .frame(minHeight: 44)
                    .accessibilityLabel("\(kind.title), \(title) increment")
                    .accessibilityIdentifier("quick-increment-\(kind.rawValue)-\(index)")
            }
            .font(.body.monospacedDigit())
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 130)
            .background(theme.surfaceElevated, in: .rect(cornerRadius: Radius.control))
        }
    }
}
