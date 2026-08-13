import SwiftUI

struct ConditioningPresetManagerRow: View {
    @Environment(\.theme) private var theme

    let name: String
    let detail: String
    let deleteMessage: String
    let onDelete: () -> Void

    @State private var isConfirmingDelete = false

    var body: some View {
        Group {
            if isConfirmingDelete {
                HStack(spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Delete \(name)?")
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(deleteMessage)
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: Space.xs)
                    Button("Cancel") {
                        withAnimation { isConfirmingDelete = false }
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                }
            } else {
                HStack(spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(name)
                            .font(.bodyStrong)
                            .foregroundStyle(theme.textPrimary)
                        Text(detail)
                            .font(.label)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: Space.sm)
                    Button("Delete \(name)", systemImage: "trash", role: .destructive) {
                        withAnimation { isConfirmingDelete = true }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
        .listRowBackground(theme.surfaceElevated)
    }
}
