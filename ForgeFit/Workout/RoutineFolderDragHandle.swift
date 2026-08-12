import Foundation
import SwiftUI

/// A visible, dedicated drag source for moving and nesting routine folders.
/// Keeping this separate from the disclosure button makes both interactions
/// predictable: the chevron expands, while this handle moves the folder.
struct RoutineFolderDragHandle: View {
    @Environment(\.theme) private var theme

    let folderName: String
    let makeItemProvider: () -> NSItemProvider

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.bodyStrong)
            .foregroundStyle(theme.textTertiary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onDrag {
                makeItemProvider()
            }
            .accessibilityLabel("Reorder \(folderName)")
            .accessibilityHint("Drag to move or nest this folder")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("reorder-folder-\(folderName)")
    }
}
