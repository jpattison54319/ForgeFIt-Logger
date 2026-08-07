import SwiftUI

/// One visible, optional whole-session effort control. The grid keeps every
/// CR10 value discoverable without adding another finish confirmation.
struct SessionRPECard: View {
    @Environment(\.theme) private var theme
    @Binding var selection: Int?

    private let rows = [Array(0...5), Array(6...10)]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.md) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Overall session effort")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text("Whole workout · CR10")
                            .font(.tag)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer()
                    Text(selection.map(Self.anchor(for:)) ?? "Not rated")
                        .font(.tag)
                        .foregroundStyle(selection == nil ? theme.textSecondary : theme.accent)
                }

                VStack(spacing: Space.sm) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        HStack(spacing: Space.sm) {
                            ForEach(rows[rowIndex], id: \.self) { value in
                                effortButton(value)
                            }
                        }
                    }
                }

                if selection != nil {
                    Button("Clear rating", action: clearRating)
                        .font(.tag)
                        .foregroundStyle(theme.textSecondary)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("clear-session-rpe")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func effortButton(_ value: Int) -> some View {
        let selected = selection == value
        return Button("\(value)") {
            selection = value
        }
        .font(.bodyStrong)
        .foregroundStyle(selected ? theme.background : theme.textPrimary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(selected ? theme.accent : theme.surfaceElevated)
        .clipShape(.rect(cornerRadius: Radius.control))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control)
                .stroke(selected ? theme.accent : theme.separator, lineWidth: selected ? 2 : 1)
        }
        .accessibilityLabel("Session effort \(value), \(Self.anchor(for: value))")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("session-rpe-\(value)")
    }

    private func clearRating() {
        selection = nil
    }

    private static func anchor(for value: Int) -> String {
        switch value {
        case 0: "Rest"
        case 1...2: "Very easy"
        case 3...4: "Moderate"
        case 5...6: "Hard"
        case 7...8: "Very hard"
        default: "Maximal"
        }
    }
}
