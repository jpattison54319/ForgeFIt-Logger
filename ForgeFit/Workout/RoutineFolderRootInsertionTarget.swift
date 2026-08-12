import SwiftUI
import UniformTypeIdentifiers

/// The transient insertion line between root folders. It occupies the normal
/// section gap, appearing only while a folder drag is directly over the slot.
struct RoutineFolderRootInsertionTarget: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let acceptsDrop: Bool
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var isTargeted = false

    var body: some View {
        let color = acceptsDrop ? theme.accent : theme.danger

        HStack(spacing: Space.sm) {
            Capsule()
                .fill(color)
                .frame(height: 2)
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Capsule()
                .fill(color)
                .frame(height: 2)
        }
        .opacity(isTargeted ? 1 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: Space.xl)
        // A fully transparent drop view can be omitted from native drag hit
        // testing. This is visually imperceptible but keeps the slot present.
        .background(theme.background.opacity(0.001))
        .contentShape(Rectangle())
        // Keep this exact boundary target above the folder's broader nesting
        // target so "insert before" remains the unambiguous top-edge action.
        .zIndex(1)
        .onDrop(of: [UTType.plainText], isTargeted: $isTargeted) { providers in
            guard acceptsDrop else { return false }
            return onDrop(providers)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isTargeted)
        // Edit Order is the non-spatial accessible equivalent. This transient
        // pointer target should not create an invisible VoiceOver stop.
        .accessibilityHidden(true)
    }
}
