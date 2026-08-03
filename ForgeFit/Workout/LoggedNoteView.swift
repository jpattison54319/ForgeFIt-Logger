import SwiftUI

/// Read-only note styling shared by workout history and exercise history
/// cards. Editing remains in the workout editor.
struct LoggedNoteView: View {
    @Environment(\.theme) private var theme
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label(title, systemImage: "note.text")
                .font(.tag)
                .foregroundStyle(theme.textSecondary)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}
